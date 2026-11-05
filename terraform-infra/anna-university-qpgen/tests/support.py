"""Shared test setup: environment, import path and in-memory fakes. No AWS access."""
import hashlib
import io
import json
import math
import os
import re
import sys
from pathlib import Path
from unittest import mock

os.environ.update(
    AWS_DEFAULT_REGION="ap-south-1", AWS_REGION="ap-south-1",
    REGISTRY_TABLE="registry", TEXTBOOK_BUCKET="tb-bucket", ARTIFACT_BUCKET="art-bucket",
    OUTPUT_BUCKET="out-bucket", INGEST_QUEUE_URL="https://sqs/ingest",
    GENERATE_QUEUE_URL="https://sqs/generate", MAX_UPLOAD_MB="100", DOWNLOAD_URL_SECONDS="900",
    JOB_RETENTION_DAYS="90", MAX_RECEIVES="3", OPENSEARCH_ENDPOINT="search.example",
    EMBEDDING_MODEL_ID="amazon.titan-embed-text-v2:0", LLM_MODEL_ID="test-model",
)
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from botocore.exceptions import ClientError  # noqa: E402

from common import registry  # noqa: E402


def conditional_failure(operation):
    return ClientError({"Error": {"Code": "ConditionalCheckFailedException", "Message": "x"}}, operation)


class FakeTable:
    """Just enough of a DynamoDB Table for common.registry."""

    def __init__(self):
        self.items = {}

    def put_item(self, Item, ConditionExpression=None):
        key = (Item["pk"], Item["sk"])

        if ConditionExpression == "attribute_not_exists(pk)" and key in self.items:
            raise conditional_failure("PutItem")

        self.items[key] = dict(Item)

    def get_item(self, Key):
        item = self.items.get((Key["pk"], Key["sk"]))
        return {"Item": dict(item)} if item else {}

    def delete_item(self, Key):
        self.items.pop((Key["pk"], Key["sk"]), None)

    def update_item(self, Key, UpdateExpression, ExpressionAttributeNames,
                    ExpressionAttributeValues, ConditionExpression, ReturnValues):
        item = self.items.get((Key["pk"], Key["sk"]))

        if item is None:
            raise conditional_failure("UpdateItem")

        if ConditionExpression.startswith("#cur IN"):
            allowed = [ExpressionAttributeValues[v] for v in re.findall(r":a\d+", ConditionExpression)]

            if item.get("status") not in allowed:
                raise conditional_failure("UpdateItem")

        for name, value in re.findall(r"(#\w+) = (:\w+)", UpdateExpression):
            item[ExpressionAttributeNames[name]] = ExpressionAttributeValues[value]

        return {"Attributes": dict(item)}

    def query(self, IndexName, KeyConditionExpression, ScanIndexForward=True, Limit=None):
        wanted = KeyConditionExpression.get_expression()["values"][1]
        rows = sorted((i for i in self.items.values() if i.get("gsi1pk") == wanted),
                      key=lambda i: i["gsi1sk"], reverse=not ScanIndexForward)
        return {"Items": [dict(r) for r in rows[:Limit]]}


class FakeS3:
    def __init__(self):
        self.objects = {}

    def put_object(self, Bucket, Key, Body, ContentType=None):
        self.objects[(Bucket, Key)] = Body if isinstance(Body, bytes) else Body.encode()

    def _get(self, Bucket, Key, VersionId=None):
        if (Bucket, Key) not in self.objects:
            raise ClientError({"Error": {"Code": "NoSuchKey", "Message": "x"}}, "GetObject")

        return self.objects[(Bucket, Key)]

    def head_object(self, **params):
        return {"ContentLength": len(self._get(**params))}

    def get_object(self, Range=None, **params):
        data = self._get(**params)

        if Range:
            end = int(Range.split("-")[1])
            data = data[: end + 1]

        return {"Body": io.BytesIO(data)}

    def generate_presigned_post(self, Bucket, Key, Fields, Conditions, ExpiresIn):
        return {"url": f"https://{Bucket}.s3.example", "fields": {**Fields, "key": Key}}

    def generate_presigned_url(self, op, Params, ExpiresIn):
        return f"https://{Params['Bucket']}.s3.example/{Params['Key']}?expires={ExpiresIn}"


class FakeSQS:
    def __init__(self):
        self.sent = []

    def send_message(self, QueueUrl, MessageBody):
        self.sent.append((QueueUrl, json.loads(MessageBody)))


class FakeTextract:
    def __init__(self, pages):
        self.pages, self.started, self.status = pages, [], "SUCCEEDED"

    def start_document_text_detection(self, DocumentLocation):
        self.started.append(DocumentLocation)
        return {"JobId": f"job-{len(self.started)}"}

    def get_document_text_detection(self, JobId, MaxResults=None, NextToken=None):
        if self.status != "SUCCEEDED":
            return {"JobStatus": self.status}

        blocks = [{"BlockType": "LINE", "Page": n, "Text": line}
                  for n, text in self.pages for line in text.split("\n")]
        return {"JobStatus": "SUCCEEDED", "Blocks": blocks}


def fake_embed(text):
    vector = [0.0] * 32

    for word in re.findall(r"[a-z0-9]+", text.lower()):
        vector[int(hashlib.md5(word.encode()).hexdigest(), 16) % 32] += 1.0

    norm = math.sqrt(sum(x * x for x in vector)) or 1.0
    return [x / norm for x in vector]


def cosine(a, b):
    return sum(x * y for x, y in zip(a, b))


class FakeSearch:
    """In-memory stand-in for common.search.SearchClient."""

    def __init__(self):
        self.chunks, self.bank, self.bulk_calls = {}, {}, 0

    def ensure_indexes(self):
        pass

    def delete_version(self, textbook_id, version):
        self.chunks = {k: v for k, v in self.chunks.items()
                       if (v["textbook_id"], v["version"]) != (textbook_id, version)}

    def bulk_index(self, index, docs):
        self.bulk_calls += 1

        for doc in docs:
            self.chunks[doc["_id"]] = {k: v for k, v in doc.items() if k != "_id"}

    def hybrid_search(self, textbook_id, version, unit, query_text, query_vector, size=6):
        rows = [c for c in self.chunks.values()
                if (c["textbook_id"], c["version"], c["unit"]) == (textbook_id, version, unit)]
        rows.sort(key=lambda c: cosine(c["embedding"], query_vector), reverse=True)
        return [{k: c[k] for k in ("chunk_id", "unit", "page", "text")} for c in rows[:size]]

    def nearest_question(self, vector, textbook_id, subject, unit):
        rows = [q for q in self.bank.values()
                if (q["textbook_id"], q["subject"], q["unit"]) == (textbook_id, subject, unit)]
        best = max(((cosine(q["embedding"], vector), q) for q in rows), key=lambda p: p[0], default=None)
        return best

    def index_question(self, doc):
        self.bank[doc["question_id"]] = doc


def install(test, modules=()):
    """Patch the registry table and AWS clients for one test. Returns the fakes."""
    fakes = type("Fakes", (), {})()
    fakes.table, fakes.s3, fakes.sqs = FakeTable(), FakeS3(), FakeSQS()
    fakes.search, fakes.textract = FakeSearch(), FakeTextract([])
    patchers = [mock.patch.object(registry, "table", lambda: fakes.table),
                mock.patch("common.bedrock.embed", fake_embed),
                mock.patch("common.bedrock.embed_many", lambda texts, workers=4: [fake_embed(t) for t in texts])]

    for module in modules:
        if hasattr(module, "_clients"):
            module._clients.clear()
            module._clients.update(s3=fakes.s3, sqs=fakes.sqs, textract=fakes.textract)

        if hasattr(module, "_search"):
            patchers.append(mock.patch.object(module, "_search", fakes.search))

    for patcher in patchers:
        patcher.start()
        test.addCleanup(patcher.stop)

    return fakes


UNITS = [
    {"unit": 1, "title": "Supervised learning", "start_page": 1, "end_page": 2},
    {"unit": 2, "title": "Ensemble methods", "start_page": 3, "end_page": 4},
]

PAGES = [
    (1, "Supervised learning maps inputs to labelled outputs. A classifier learns from examples. "
        "Regression predicts continuous values while classification predicts categories. " * 3),
    (2, "Overfitting happens when a model memorises noise. Regularisation and cross validation reduce it. " * 4),
    (3, "Bagging trains models on bootstrap samples and averages them. Random forests are bagged trees. " * 4),
    (4, "Boosting trains models in sequence so each corrects the previous errors. Gradient boosting is common. " * 4),
]


def add_textbook(fakes, status="COMPLETED", textbook_id="a" * 32, version="v1", subject="Machine Learning"):
    item = registry.create_textbook(textbook_id, version, "ML Textbook", subject, UNITS,
                                    f"textbooks/{textbook_id}/{version}/book.docx", "admin-sub")

    if status != "PENDING_UPLOAD":
        fakes.table.items[(item["pk"], item["sk"])]["status"] = status

    return textbook_id, version
