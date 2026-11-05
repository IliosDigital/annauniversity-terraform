"""Textbook ingestion coordinator, triggered from SQS (fed by EventBridge S3 events).

validate -> extract text (DOCX parser or Textract OCR) -> clean and chunk by unit
-> embed with Titan -> bulk index in OpenSearch -> mark the textbook COMPLETED.

Permanent problems (wrong file type, empty text) mark the textbook FAILED and
acknowledge the message. Transient problems are raised so SQS retries; after
the last retry the message goes to the dead-letter queue and the textbook is
marked FAILED so the UI shows a reason.
"""
import json
import os
import re
import time

import boto3

from common import bedrock, chunking, documents, registry, search
from common.log import log, log_error

KEY_PATTERN = re.compile(r"^textbooks/([0-9a-f]{32})/([A-Za-z0-9._-]{1,32})/([^/]+)$")
ALLOWED = {"pdf": "pdf", "docx": "docx"}
MIN_TOTAL_CHARS = 500
POLL_SECONDS = 5
SAFE_MARGIN_MS = 90_000

_clients = {}
_search = None


class Permanent(Exception):
    """The file cannot be processed; retrying will not help."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


def _client(name):
    if name not in _clients:
        _clients[name] = boto3.client(name)

    return _clients[name]


def search_client():
    global _search

    if _search is None:
        _search = search.SearchClient()

    return _search


# --- extraction ----------------------------------------------------------------
def _textract_pages(bucket, key, version_id, textbook, event_key, remaining_ms):
    """Start (or resume) an async Textract job and poll it. Returns [(page, text)].

    A job is resumed only when it belongs to this same upload event, so a
    re-uploaded file never reuses the text of an older job."""
    textract = _client("textract")
    job_id = textbook.get("textract_job_id") if textbook.get("textract_event") == event_key else None

    if job_id and textract.get_document_text_detection(JobId=job_id, MaxResults=1)["JobStatus"] == "FAILED":
        job_id = None

    if not job_id:
        location = {"S3Object": {"Bucket": bucket, "Name": key,
                                 **({"Version": version_id} if version_id else {})}}
        job_id = textract.start_document_text_detection(DocumentLocation=location)["JobId"]
        registry.set_textbook_status(textbook["textbook_id"], textbook["version"],
                                     ("PROCESSING",), "PROCESSING",
                                     textract_job_id=job_id, textract_event=event_key)

    while True:
        status = textract.get_document_text_detection(JobId=job_id, MaxResults=1)

        if status["JobStatus"] == "SUCCEEDED":
            break

        if status["JobStatus"] == "FAILED":
            raise RuntimeError("OCR job failed: " + str(status.get("StatusMessage", ""))[:120])

        if remaining_ms() < SAFE_MARGIN_MS:
            raise RuntimeError("OCR still running; will resume on retry")

        time.sleep(POLL_SECONDS)

    pages, token = {}, None

    while True:
        reply = textract.get_document_text_detection(
            JobId=job_id, **({"NextToken": token} if token else {}))

        for block in reply.get("Blocks", []):
            if block["BlockType"] == "LINE":
                pages.setdefault(block.get("Page", 1), []).append(block["Text"])

        token = reply.get("NextToken")

        if not token:
            break

    return [(n, "\n".join(lines)) for n, lines in sorted(pages.items())]


def extract_pages(bucket, key, version_id, kind, textbook, event_key, remaining_ms):
    if kind == "docx":
        params = {"Bucket": bucket, "Key": key, **({"VersionId": version_id} if version_id else {})}
        return documents.read_docx_pages(_client("s3").get_object(**params)["Body"].read())

    return _textract_pages(bucket, key, version_id, textbook, event_key, remaining_ms)


# --- processing ------------------------------------------------------------------
def validate_object(bucket, key, version_id):
    """Check the object itself, not just its name: size and magic bytes."""
    params = {"Bucket": bucket, "Key": key, **({"VersionId": version_id} if version_id else {})}
    head = _client("s3").head_object(**params)
    max_bytes = int(os.environ["MAX_UPLOAD_MB"]) * 1024 * 1024

    if head["ContentLength"] > max_bytes or head["ContentLength"] == 0:
        raise Permanent("FILE_SIZE", "File is empty or larger than the allowed size")

    extension = key.rsplit(".", 1)[-1].lower()
    first = _client("s3").get_object(**params, Range="bytes=0-4095")["Body"].read()
    kind = "pdf" if first[:5] == b"%PDF-" else ("docx" if first[:4] == b"PK\x03\x04" else None)

    if extension not in ALLOWED or kind != ALLOWED[extension]:
        raise Permanent("UNSUPPORTED_FILE", "File type does not match its extension, or is not allowed")

    return kind


def process(event, remaining_ms):
    detail = event["detail"]
    bucket, key = detail["bucket"]["name"], detail["object"]["key"]
    version_id = detail["object"].get("version-id")
    match = KEY_PATTERN.match(key)

    if bucket != os.environ["TEXTBOOK_BUCKET"] or not match:
        log("ingest_ignored", reason="unexpected_object")
        return

    textbook_id, version, _ = match.groups()
    textbook = registry.get_textbook(textbook_id, version)

    if not textbook:
        log("ingest_ignored", reason="not_registered", textbook_id=textbook_id)
        return

    event_key = f"{bucket}/{key}#{version_id or detail.get('reprocess_id', 'latest')}"

    if not registry.claim_event(event_key):
        log("ingest_duplicate_event", textbook_id=textbook_id, version=version)
        return

    started = time.perf_counter()

    try:
        textbook = registry.set_textbook_status(
            textbook_id, version, ("PENDING_UPLOAD", "UPLOADED", "COMPLETED", "FAILED"),
            "PROCESSING", error_code=None)
    except registry.Conflict:
        registry.release_event(event_key)
        log("ingest_ignored", reason="already_processing", textbook_id=textbook_id)
        return

    try:
        kind = validate_object(bucket, key, version_id)
        pages = extract_pages(bucket, key, version_id, kind, textbook, event_key, remaining_ms)
        pages = [(n, chunking.normalize_whitespace(t)) for n, t in pages]
        total_chars = sum(len(t) for _, t in pages)

        if total_chars < MIN_TOTAL_CHARS:
            raise Permanent("EMPTY_TEXT", "Almost no text could be extracted (corrupt or unreadable scan)")

        chunks = chunking.chunk_pages(pages, textbook["units"], textbook_id, version)

        if not chunks:
            raise Permanent("NO_CHUNKS", "No text fell inside the page ranges of the declared units")

        artifacts = os.environ["ARTIFACT_BUCKET"]
        prefix = f"{textbook_id}/{version}"
        _client("s3").put_object(Bucket=artifacts, Key=f"intermediate/{prefix}/pages.json",
                                 Body=json.dumps(pages).encode(), ContentType="application/json")
        _client("s3").put_object(
            Bucket=artifacts, Key=f"processed/{prefix}/chunks.json",
            Body=json.dumps([{k: c[k] for k in ("chunk_id", "unit", "page")} for c in chunks]).encode(),
            ContentType="application/json")

        vectors = bedrock.embed_many([c["text"] for c in chunks])
        index = search_client()
        index.ensure_indexes()
        index.delete_version(textbook_id, version)
        index.bulk_index(search.CHUNKS_INDEX, [
            {"_id": c["chunk_id"], **c, "embedding": v} for c, v in zip(chunks, vectors)])

        registry.set_textbook_status(
            textbook_id, version, ("PROCESSING",), "COMPLETED",
            page_count=len(pages), chunk_count=len(chunks), completed_at=registry.now())
        log("ingest_completed", textbook_id=textbook_id, version=version, pages=len(pages),
            chunks=len(chunks), seconds=round(time.perf_counter() - started, 1))

    except Permanent as problem:
        registry.set_textbook_status(textbook_id, version, ("PROCESSING",), "FAILED",
                                     error_code=problem.code, error_message=problem.message)
        log("ingest_failed", textbook_id=textbook_id, version=version, error_code=problem.code)

    except Exception:
        # Transient: put the textbook back so the retry can claim it again.
        registry.release_event(event_key)
        registry.set_textbook_status(textbook_id, version, ("PROCESSING",), "UPLOADED")
        raise


def lambda_handler(event, context):
    failures = []
    max_receives = int(os.environ["MAX_RECEIVES"])

    for record in event["Records"]:
        try:
            process(json.loads(record["body"]), context.get_remaining_time_in_millis)
        except Exception:
            receives = int(record.get("attributes", {}).get("ApproximateReceiveCount", "1"))
            log_error("ingest_error", message_id=record["messageId"], receive_count=receives)

            if receives >= max_receives:
                _mark_failed(record)  # leave a visible reason before the DLQ takes it

            # Always report the failure: SQS retries it, then moves it to the DLQ.
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}


def _mark_failed(record):
    """Last attempt: leave a visible reason; SQS will move the message to the DLQ."""
    try:
        key = json.loads(record["body"])["detail"]["object"]["key"]
        textbook_id, version, _ = KEY_PATTERN.match(key).groups()
        registry.set_textbook_status(textbook_id, version, ("PROCESSING", "UPLOADED"), "FAILED",
                                     error_code="PROCESSING_ERROR",
                                     error_message="Processing failed after retries; an administrator can reprocess")
    except Exception:
        log_error("ingest_mark_failed_error", message_id=record["messageId"])
