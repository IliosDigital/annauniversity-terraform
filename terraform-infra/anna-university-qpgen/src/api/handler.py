"""HTTP API: textbook registry, upload URLs, reprocessing and question-paper jobs.

Behind API Gateway with a Cognito authorizer. Groups: administrator manages
textbooks; faculty and administrator request and download question papers.
"""
import json
import os
import re
import uuid

import boto3
from botocore.config import Config

from common import registry
from common.log import log, log_error

DIFFICULTIES = ("Easy", "Medium", "Hard", "Mixed")
FORMATS = ("docx", "json")
CONTENT_TYPES = {
    "pdf": "application/pdf",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
}
VERSION = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
FILENAME = re.compile(r"^[A-Za-z0-9._ -]{1,100}$")
TEXTBOOK_ID = re.compile(r"^[0-9a-f]{32}$")

_clients = {}


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def _s3():
    if "s3" not in _clients:
        _clients["s3"] = boto3.client("s3", config=Config(signature_version="s3v4"))

    return _clients["s3"]


def _sqs():
    if "sqs" not in _clients:
        _clients["sqs"] = boto3.client("sqs")

    return _clients["sqs"]


# --- request helpers ---------------------------------------------------------
def _response(status, payload=None, headers=None):
    cors = {"Access-Control-Allow-Origin": os.environ["ALLOWED_ORIGIN"]} if os.environ.get("ALLOWED_ORIGIN") else {}

    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", **cors, **(headers or {})},
        "body": "" if payload is None else json.dumps(payload, default=str),
    }


def _claims(event):
    return (event.get("requestContext", {}).get("authorizer") or {}).get("claims") or {}


def _groups(claims):
    raw = claims.get("cognito:groups", "")
    raw = raw if isinstance(raw, str) else " ".join(raw)
    return {g for g in re.split(r"[\s,\[\]]+", raw) if g}


def _require(event, *allowed):
    claims = _claims(event)

    if not _groups(claims) & set(allowed):
        raise ApiError(403, "You do not have permission to do this")

    return claims["sub"], claims.get("email", "")


def _body(event):
    try:
        data = json.loads(event.get("body") or "")
    except ValueError:
        raise ApiError(400, "Body must be valid JSON")

    if not isinstance(data, dict):
        raise ApiError(400, "Body must be a JSON object")

    return data


def _text(data, field, max_len=200):
    value = data.get(field)

    if not isinstance(value, str) or not value.strip() or len(value) > max_len:
        raise ApiError(400, f"{field} must be a non-empty string of at most {max_len} characters")

    return value.strip()


def _int(value, field, low, high):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ApiError(400, f"{field} must be an integer between {low} and {high}")

    return value


def _units(raw):
    if not isinstance(raw, list) or not 1 <= len(raw) <= 30:
        raise ApiError(400, "units must be a list of 1 to 30 entries")

    units, seen = [], set()

    for item in raw:
        if not isinstance(item, dict):
            raise ApiError(400, "each unit must be an object")

        number = _int(item.get("unit"), "unit", 1, 99)
        start = _int(item.get("start_page"), "start_page", 1, 5000)
        end = _int(item.get("end_page"), "end_page", 1, 5000)

        if number in seen or end < start:
            raise ApiError(400, "units must be unique and end_page must not precede start_page")

        seen.add(number)
        units.append({"unit": number, "title": _text(item, "title", 120),
                      "start_page": start, "end_page": end})

    return units


def _path(event, name, pattern):
    value = (event.get("pathParameters") or {}).get(name, "")

    if not pattern.match(value):
        raise ApiError(400, f"{name} is not valid")

    return value


# --- textbooks -----------------------------------------------------------------
def create_textbook(event):
    user, _ = _require(event, "administrator")
    data = _body(event)
    title, subject = _text(data, "title"), _text(data, "subject", 100)
    version = _text(data, "version", 32)
    filename = _text(data, "filename", 100)
    extension = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""

    if not VERSION.match(version) or not FILENAME.match(filename) or extension not in CONTENT_TYPES:
        raise ApiError(400, "version, filename or file type is not allowed (pdf and docx only)")

    units = _units(data.get("units"))
    textbook_id = uuid.uuid4().hex
    key = f"textbooks/{textbook_id}/{version}/{filename}"
    max_bytes = int(os.environ["MAX_UPLOAD_MB"]) * 1024 * 1024

    try:
        registry.create_textbook(textbook_id, version, title, subject, units, key, user)
    except registry.Conflict:
        raise ApiError(409, "This textbook version already exists")

    upload = _s3().generate_presigned_post(
        Bucket=os.environ["TEXTBOOK_BUCKET"], Key=key,
        Fields={"Content-Type": CONTENT_TYPES[extension]},
        Conditions=[{"Content-Type": CONTENT_TYPES[extension]},
                    ["content-length-range", 1, max_bytes]],
        ExpiresIn=900,
    )
    log("textbook_registered", textbook_id=textbook_id, version=version, user=user)
    return _response(201, {"textbook_id": textbook_id, "version": version,
                           "status": "PENDING_UPLOAD", "upload": upload, "expires_in": 900})


def list_textbooks(event):
    _require(event, "faculty", "administrator")
    status = (event.get("queryStringParameters") or {}).get("status")

    if status is not None and status not in registry.TEXTBOOK_STATUSES:
        raise ApiError(400, "status is not valid")

    return _response(200, {"textbooks": [
        _textbook_view(i) for i in registry.list_textbooks(status)]})


def _textbook_view(item):
    keys = ("textbook_id", "version", "title", "subject", "units", "status", "error_code",
            "error_message", "page_count", "chunk_count", "created_at", "updated_at")
    return {k: item[k] for k in keys if k in item}


def get_textbook(event):
    _require(event, "faculty", "administrator")
    item = registry.get_textbook(_path(event, "textbook_id", TEXTBOOK_ID),
                                 _path(event, "version", VERSION))

    if not item:
        raise ApiError(404, "Textbook not found")

    return _response(200, _textbook_view(item))


def reprocess_textbook(event):
    user, _ = _require(event, "administrator")
    textbook_id, version = _path(event, "textbook_id", TEXTBOOK_ID), _path(event, "version", VERSION)
    item = registry.get_textbook(textbook_id, version)

    if not item:
        raise ApiError(404, "Textbook not found")

    try:
        registry.set_textbook_status(textbook_id, version, ("COMPLETED", "FAILED"), "UPLOADED",
                                     error_code=None)
    except registry.Conflict:
        raise ApiError(409, "Only COMPLETED or FAILED textbooks can be reprocessed")

    _sqs().send_message(
        QueueUrl=os.environ["INGEST_QUEUE_URL"],
        MessageBody=json.dumps({
            "source": "reprocess",
            "detail": {"bucket": {"name": os.environ["TEXTBOOK_BUCKET"]},
                       "object": {"key": item["s3_key"]},
                       "reprocess_id": uuid.uuid4().hex},
        }),
    )
    log("textbook_reprocess_requested", textbook_id=textbook_id, version=version, user=user)
    return _response(202, {"textbook_id": textbook_id, "version": version, "status": "UPLOADED"})


# --- question papers -------------------------------------------------------------
def _paper_request(data):
    request = {
        "textbook_id": _text(data, "textbook_id", 32),
        "version": _text(data, "version", 32),
        "subject": _text(data, "subject", 100),
        "difficulty": data.get("difficulty"),
        "count": _int(data.get("count"), "count", 1, 100),
        "include_answer_key": data.get("include_answer_key", False),
        "formats": data.get("formats", ["docx"]),
        "title": str(data.get("title") or "")[:120],
    }
    units = data.get("units")

    if not isinstance(units, list) or not units or len(units) > 30:
        raise ApiError(400, "units must be a list of 1 to 30 unit numbers")

    request["units"] = sorted({_int(u, "unit", 1, 99) for u in units})

    if request["difficulty"] not in DIFFICULTIES:
        raise ApiError(400, "difficulty must be Easy, Medium, Hard or Mixed")

    if not isinstance(request["include_answer_key"], bool):
        raise ApiError(400, "include_answer_key must be true or false")

    formats = request["formats"]

    if not isinstance(formats, list) or not formats or not set(formats) <= set(FORMATS):
        raise ApiError(400, "formats must be a non-empty list of docx and/or json (pdf is not supported)")

    request["formats"] = sorted(set(formats))
    request["sections"] = _sections(data.get("sections"), request["count"])
    return request


def _sections(raw, count):
    if raw is None:
        return None

    if not isinstance(raw, list) or not 1 <= len(raw) <= 10:
        raise ApiError(400, "sections must be a list of 1 to 10 entries")

    sections = [{"name": _text(s, "name", 60), "count": _int(s.get("count"), "count", 1, 100),
                 "marks": _int(s.get("marks"), "marks", 1, 100)} for s in raw if isinstance(s, dict)]

    if len(sections) != len(raw) or sum(s["count"] for s in sections) != count:
        raise ApiError(400, "section counts must add up to the number of questions")

    return sections


def create_paper(event):
    user, _ = _require(event, "faculty", "administrator")
    request = _paper_request(_body(event))
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    correlation_id = headers.get("x-correlation-id") or event.get("requestContext", {}).get("requestId", "")
    idem_key = headers.get("idempotency-key")

    if idem_key:
        if not re.match(r"^[A-Za-z0-9_-]{8,64}$", idem_key):
            raise ApiError(400, "Idempotency-Key must be 8-64 letters, digits, - or _")

        existing = registry.find_request(user, idem_key)

        if existing:
            return _response(200, {"job_id": existing, "status": registry.get_job(existing)["status"],
                                   "replayed": True})

    textbook = registry.get_textbook(request["textbook_id"], request["version"])

    if not textbook:
        raise ApiError(404, "Textbook not found")

    if textbook["status"] != "COMPLETED":
        raise ApiError(409, "Only COMPLETED textbooks can be used; this one is " + textbook["status"])

    if textbook["subject"].casefold() != request["subject"].casefold():
        raise ApiError(400, "subject does not match the selected textbook")

    available = {u["unit"] for u in textbook["units"]}

    if not set(request["units"]) <= available:
        raise ApiError(400, "units must be units of the selected textbook")

    request["subject"] = textbook["subject"]
    job_id = str(uuid.uuid4())

    if idem_key and not registry.store_request(user, idem_key, job_id):
        existing = registry.find_request(user, idem_key)
        return _response(200, {"job_id": existing, "status": "ACCEPTED", "replayed": True})

    registry.create_job(job_id, user, request, correlation_id,
                        days=int(os.environ["JOB_RETENTION_DAYS"]))
    _sqs().send_message(QueueUrl=os.environ["GENERATE_QUEUE_URL"],
                        MessageBody=json.dumps({"job_id": job_id}))
    log("job_accepted", job_id=job_id, correlation_id=correlation_id, user=user,
        textbook_id=request["textbook_id"], count=request["count"])
    return _response(202, {"job_id": job_id, "status": "ACCEPTED", "correlation_id": correlation_id})


def _job_view(job, with_links):
    view = {k: job[k] for k in ("job_id", "status", "request", "correlation_id", "error_code",
                                "error_message", "created_at", "updated_at") if k in job}

    if with_links and job["status"] == "COMPLETED":
        seconds = int(os.environ["DOWNLOAD_URL_SECONDS"])
        view["downloads"] = {
            name: _s3().generate_presigned_url(
                "get_object",
                Params={"Bucket": os.environ["OUTPUT_BUCKET"], "Key": key,
                        "ResponseContentDisposition": f'attachment; filename="{key.rsplit("/", 1)[-1]}"'},
                ExpiresIn=seconds)
            for name, key in job.get("outputs", {}).items()
        }
        view["downloads_expire_in"] = seconds

    return view


def get_paper(event):
    user, _ = _require(event, "faculty", "administrator")
    job_id = _path(event, "job_id", re.compile(r"^[0-9a-f-]{36}$"))
    job = registry.get_job(job_id)
    is_admin = "administrator" in _groups(_claims(event))

    if not job or (job["user"] != user and not is_admin):
        raise ApiError(404, "Job not found")

    return _response(200, _job_view(job, with_links=True))


def list_papers(event):
    user, _ = _require(event, "faculty", "administrator")
    return _response(200, {"jobs": [_job_view(j, with_links=False) for j in registry.list_jobs(user)]})


def health(event):
    return _response(200, {"status": "ok"})


ROUTES = {
    ("GET", "/health"): health,
    ("GET", "/textbooks"): list_textbooks,
    ("POST", "/textbooks"): create_textbook,
    ("GET", "/textbooks/{textbook_id}/{version}"): get_textbook,
    ("POST", "/textbooks/{textbook_id}/{version}/reprocess"): reprocess_textbook,
    ("GET", "/question-papers"): list_papers,
    ("POST", "/question-papers"): create_paper,
    ("GET", "/question-papers/{job_id}"): get_paper,
}


def lambda_handler(event, context):
    method, resource = event.get("httpMethod", ""), event.get("resource", "")

    try:
        route = ROUTES.get((method, resource))

        if route is None:
            raise ApiError(404, "Route not found")

        return route(event)
    except ApiError as error:
        return _response(error.status, {"message": error.message})
    except Exception:
        log_error("unhandled_error", method=method, resource=resource,
                  request_id=event.get("requestContext", {}).get("requestId"))
        return _response(500, {"message": "Internal server error"})
