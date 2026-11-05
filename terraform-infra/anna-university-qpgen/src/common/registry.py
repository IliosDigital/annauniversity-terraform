"""Job and textbook registry in DynamoDB (single table).

pk / sk layout
  TEXTBOOK#<id>     VERSION#<v>   textbook version: status, subject, units, errors
  JOB#<id>          JOB           generation job: status, request, outputs, errors
  IDEM#<key>        EVENT         processed S3 event (ingestion idempotency)
  REQ#<user>#<key>  JOB           client idempotency key -> job id
  QHASH#<tb>#<h>    Q             exact-duplicate ledger of accepted questions
gsi1 (gsi1pk, gsi1sk) lists textbooks (gsi1pk = TEXTBOOK) and a user's jobs.
"""
import os
import time
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

TEXTBOOK_STATUSES = ("PENDING_UPLOAD", "UPLOADED", "PROCESSING", "COMPLETED", "FAILED")
JOB_STATUSES = ("ACCEPTED", "PROCESSING", "COMPLETED", "FAILED")


class Conflict(Exception):
    """A conditional write was refused: the item is missing or in another state."""


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def ttl(days):
    return int(time.time()) + days * 86400


def table():
    return boto3.resource("dynamodb").Table(os.environ["REGISTRY_TABLE"])


def _tb_key(textbook_id, version):
    return {"pk": f"TEXTBOOK#{textbook_id}", "sk": f"VERSION#{version}"}


def _set(table_, key, values, allowed=None):
    """Conditional update. allowed = statuses the item must currently have."""
    names = {f"#{k}": k for k in values}
    expression = "SET " + ", ".join(f"#{k} = :{k}" for k in values)
    params = {
        "Key": key,
        "UpdateExpression": expression,
        "ExpressionAttributeNames": names,
        "ExpressionAttributeValues": {f":{k}": v for k, v in values.items()},
        "ReturnValues": "ALL_NEW",
    }

    if allowed is None:
        params["ConditionExpression"] = "attribute_exists(pk)"
    else:
        params["ExpressionAttributeNames"]["#cur"] = "status"
        for i, status in enumerate(allowed):
            params["ExpressionAttributeValues"][f":a{i}"] = status
        params["ConditionExpression"] = "#cur IN (" + ", ".join(f":a{i}" for i in range(len(allowed))) + ")"

    try:
        return table_.update_item(**params)["Attributes"]
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise Conflict() from None
        raise


# --- textbooks ---------------------------------------------------------------
def create_textbook(textbook_id, version, title, subject, units, s3_key, owner):
    item = {
        **_tb_key(textbook_id, version),
        "gsi1pk": "TEXTBOOK",
        "gsi1sk": f"{subject.casefold()}#{title.casefold()}#{version}",
        "textbook_id": textbook_id, "version": version, "title": title,
        "subject": subject, "units": units, "s3_key": s3_key,
        "status": "PENDING_UPLOAD", "created_by": owner,
        "created_at": now(), "updated_at": now(),
    }

    try:
        table().put_item(Item=item, ConditionExpression="attribute_not_exists(pk)")
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise Conflict() from None
        raise

    return item


def get_textbook(textbook_id, version):
    return table().get_item(Key=_tb_key(textbook_id, version)).get("Item")


def list_textbooks(status=None):
    items = table().query(
        IndexName="gsi1", KeyConditionExpression=Key("gsi1pk").eq("TEXTBOOK")
    )["Items"]
    return [i for i in items if status is None or i["status"] == status]


def set_textbook_status(textbook_id, version, allowed, status, **extra):
    return _set(table(), _tb_key(textbook_id, version),
                {"status": status, "updated_at": now(), **extra}, allowed)


# --- ingestion idempotency -----------------------------------------------------
def claim_event(event_key, days=14):
    """True the first time an S3 object version is seen, False for repeats."""
    try:
        table().put_item(
            Item={"pk": f"IDEM#{event_key}", "sk": "EVENT", "claimed_at": now(),
                  "expires_at": ttl(days)},
            ConditionExpression="attribute_not_exists(pk)",
        )
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def release_event(event_key):
    table().delete_item(Key={"pk": f"IDEM#{event_key}", "sk": "EVENT"})


# --- generation jobs -------------------------------------------------------------
def create_job(job_id, user, request, correlation_id, days=90):
    item = {
        "pk": f"JOB#{job_id}", "sk": "JOB", "job_id": job_id, "status": "ACCEPTED",
        "gsi1pk": f"USER#{user}", "gsi1sk": f"JOB#{now()}",
        "user": user, "request": request, "correlation_id": correlation_id,
        "attempts": 0, "created_at": now(), "updated_at": now(), "expires_at": ttl(days),
    }
    table().put_item(Item=item, ConditionExpression="attribute_not_exists(pk)")
    return item


def get_job(job_id):
    return table().get_item(Key={"pk": f"JOB#{job_id}", "sk": "JOB"}).get("Item")


def list_jobs(user, limit=25):
    return table().query(
        IndexName="gsi1",
        KeyConditionExpression=Key("gsi1pk").eq(f"USER#{user}"),
        ScanIndexForward=False, Limit=limit,
    )["Items"]


def set_job_status(job_id, allowed, status, **extra):
    return _set(table(), {"pk": f"JOB#{job_id}", "sk": "JOB"},
                {"status": status, "updated_at": now(), **extra}, allowed)


def find_request(user, idempotency_key):
    item = table().get_item(Key={"pk": f"REQ#{user}#{idempotency_key}", "sk": "JOB"}).get("Item")
    return item["job_id"] if item else None


def store_request(user, idempotency_key, job_id, days=2):
    """True if this key was new; False if another request stored it first."""
    try:
        table().put_item(
            Item={"pk": f"REQ#{user}#{idempotency_key}", "sk": "JOB", "job_id": job_id,
                  "expires_at": ttl(days)},
            ConditionExpression="attribute_not_exists(pk)",
        )
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


# --- accepted questions ------------------------------------------------------------
def question_seen(textbook_id, normalized_hash):
    return "Item" in table().get_item(
        Key={"pk": f"QHASH#{textbook_id}#{normalized_hash}", "sk": "Q"})


def record_question(textbook_id, normalized_hash, question_id):
    """True if recorded; False if an identical question was accepted before."""
    try:
        table().put_item(
            Item={"pk": f"QHASH#{textbook_id}#{normalized_hash}", "sk": "Q",
                  "question_id": question_id, "created_at": now()},
            ConditionExpression="attribute_not_exists(pk)",
        )
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise
