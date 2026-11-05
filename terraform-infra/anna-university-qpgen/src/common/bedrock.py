"""Amazon Bedrock calls: Titan text embeddings and Claude through Converse."""
import json
import os
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

EMBED_DIMENSIONS = 1024
MAX_EMBED_CHARS = 8000

_clients = {}
_forced_tool_refused = set()  # models that accept only toolChoice auto


def _client(read_timeout, attempts):
    key = (read_timeout, attempts)

    if key not in _clients:
        _clients[key] = boto3.client(
            "bedrock-runtime",
            config=Config(
                connect_timeout=5,
                read_timeout=read_timeout,
                retries={"max_attempts": attempts, "mode": "adaptive"},
            ),
        )

    return _clients[key]


def embed(text):
    """One 1024-dimension normalized Titan v2 embedding."""
    reply = _client(30, 6).invoke_model(
        modelId=os.environ["EMBEDDING_MODEL_ID"],
        contentType="application/json",
        accept="application/json",
        body=json.dumps({
            "inputText": text[:MAX_EMBED_CHARS],
            "dimensions": EMBED_DIMENSIONS,
            "normalize": True,
        }),
    )
    return json.loads(reply["body"].read())["embedding"]


def embed_many(texts, workers=4):
    with ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(embed, texts))


def converse_tool(system, user, tool, max_tokens=4000, read_timeout=120):
    """One Claude call that should answer through `tool`. Returns (input dict, usage).

    A forced tool call is the most reliable, but some models (Sonnet 5.5 was
    checked against Bedrock) reject it and accept only automatic tool choice. For
    those the call is repeated once with `auto`, and remembered for next time."""
    model = os.environ["LLM_MODEL_ID"]
    forced = {"tool": {"name": tool["toolSpec"]["name"]}}
    choice = {"auto": {}} if model in _forced_tool_refused else forced

    while True:
        try:
            reply = _client(read_timeout, 3).converse(
                modelId=model,
                system=[{"text": system}],
                messages=[{"role": "user", "content": [{"text": user}]}],
                inferenceConfig={"maxTokens": max_tokens},
                toolConfig={"tools": [tool], "toolChoice": choice},
            )
            break
        except ClientError as error:
            refused = (error.response["Error"]["Code"] == "ValidationException"
                       and "tool_choice" in error.response["Error"]["Message"])

            if choice is not forced or not refused:
                raise

            _forced_tool_refused.add(model)
            choice = {"auto": {}}

    blocks = reply["output"]["message"]["content"]
    answer = next((b["toolUse"]["input"] for b in blocks if "toolUse" in b), {})
    return answer, reply.get("usage", {})
