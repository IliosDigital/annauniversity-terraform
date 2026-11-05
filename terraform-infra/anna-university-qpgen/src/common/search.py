"""OpenSearch access with SigV4 signing (standard library plus botocore).

Two indexes, as in the reference architecture:
  textbook_chunks  BM25 text plus vector embeddings of textbook passages
  question_bank    accepted questions plus vectors, for semantic duplicate checks
"""
import json
import os
import time
import urllib.error
import urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

CHUNKS_INDEX = "textbook_chunks"
BANK_INDEX = "question_bank"
DIMENSIONS = 1024
RRF_K = 60

_VECTOR = {
    "type": "knn_vector",
    "dimension": DIMENSIONS,
    "method": {"name": "hnsw", "engine": "lucene", "space_type": "cosinesimil"},
}
MAPPINGS = {
    CHUNKS_INDEX: {
        "settings": {"index": {"knn": True}},
        "mappings": {"properties": {
            "chunk_id": {"type": "keyword"},
            "textbook_id": {"type": "keyword"},
            "version": {"type": "keyword"},
            "unit": {"type": "integer"},
            "page": {"type": "integer"},
            "text": {"type": "text"},
            "embedding": _VECTOR,
        }},
    },
    BANK_INDEX: {
        "settings": {"index": {"knn": True}},
        "mappings": {"properties": {
            "question_id": {"type": "keyword"},
            "textbook_id": {"type": "keyword"},
            "source_version": {"type": "keyword"},
            "subject": {"type": "keyword"},
            "unit": {"type": "integer"},
            "difficulty": {"type": "keyword"},
            "normalized_hash": {"type": "keyword"},
            "question": {"type": "text"},
            "embedding": _VECTOR,
        }},
    },
}


class SearchError(Exception):
    pass


class SearchClient:
    def __init__(self, endpoint=None, region=None):
        self.host = endpoint or os.environ["OPENSEARCH_ENDPOINT"]
        self.region = region or os.environ.get("AWS_REGION", "ap-south-1")

    # --- transport (replaced in tests) -------------------------------------
    def request(self, method, path, body=None, raw=None, ok=(200, 201)):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else b"")
        url = f"https://{self.host}{path}"
        headers = {"Content-Type": "application/x-ndjson" if raw is not None else "application/json"}
        signed = AWSRequest(method=method, url=url, data=data, headers=headers)
        SigV4Auth(boto3.Session().get_credentials(), "es", self.region).add_auth(signed)
        request = urllib.request.Request(
            url, data=data or None, headers=dict(signed.headers), method=method
        )

        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:300]
            raise SearchError(f"{method} {path} -> {error.code}: {detail}") from None

    # --- indexes -------------------------------------------------------------
    def ensure_indexes(self):
        for name, definition in MAPPINGS.items():
            try:
                self.request("PUT", f"/{name}", definition)
            except SearchError as error:
                if "resource_already_exists_exception" not in str(error):
                    raise

    def bulk_index(self, index, docs, attempts=3):
        """Index docs (each needs '_id'); retry only the items that failed."""
        pending = list(docs)

        for attempt in range(attempts):
            lines = []

            for doc in pending:
                body = {k: v for k, v in doc.items() if k != "_id"}
                lines.append(json.dumps({"index": {"_index": index, "_id": doc["_id"]}}))
                lines.append(json.dumps(body))

            result = self.request("POST", "/_bulk", raw=("\n".join(lines) + "\n").encode())

            if not result.get("errors"):
                return

            failed = {
                item["index"]["_id"]
                for item in result["items"]
                if item["index"].get("status", 200) >= 300
            }
            pending = [d for d in pending if d["_id"] in failed]
            time.sleep(2 ** attempt)

        raise SearchError(f"{len(pending)} documents failed to index after {attempts} attempts")

    def delete_version(self, textbook_id, version):
        """Remove a textbook version's chunks before it is re-indexed."""
        self.request("POST", f"/{CHUNKS_INDEX}/_delete_by_query?refresh=true", {
            "query": {"bool": {"filter": [
                {"term": {"textbook_id": textbook_id}}, {"term": {"version": version}},
            ]}}
        })

    # --- retrieval -------------------------------------------------------------
    def hybrid_search(self, textbook_id, version, unit, query_text, query_vector, size=6):
        """BM25 and vector search, scoped to one completed textbook version and
        unit, merged with reciprocal rank fusion."""
        filters = [
            {"term": {"textbook_id": textbook_id}},
            {"term": {"version": version}},
            {"term": {"unit": unit}},
        ]
        fields = ["chunk_id", "unit", "page", "text"]
        lexical = self.request("POST", f"/{CHUNKS_INDEX}/_search", {
            "size": size, "_source": fields,
            "query": {"bool": {"filter": filters, "must": [{"match": {"text": query_text}}]}},
        })
        vector = self.request("POST", f"/{CHUNKS_INDEX}/_search", {
            "size": size, "_source": fields,
            "query": {"knn": {"embedding": {
                "vector": query_vector, "k": size, "filter": {"bool": {"filter": filters}},
            }}},
        })
        scores, docs = {}, {}

        for hits in (lexical["hits"]["hits"], vector["hits"]["hits"]):
            for rank, hit in enumerate(hits, start=1):
                doc = hit["_source"]
                docs[doc["chunk_id"]] = doc
                scores[doc["chunk_id"]] = scores.get(doc["chunk_id"], 0) + 1 / (RRF_K + rank)

        best = sorted(scores, key=scores.get, reverse=True)[:size]
        return [docs[chunk_id] for chunk_id in best]

    def nearest_question(self, vector, textbook_id, subject, unit):
        """Most similar accepted question in the same textbook, subject and
        unit, as (cosine similarity, document), or None."""
        result = self.request("POST", f"/{BANK_INDEX}/_search", {
            "size": 1, "_source": ["question_id", "question"],
            "query": {"knn": {"embedding": {"vector": vector, "k": 1, "filter": {"bool": {"filter": [
                {"term": {"textbook_id": textbook_id}},
                {"term": {"subject": subject}},
                {"term": {"unit": unit}},
            ]}}}}},
        })
        hits = result["hits"]["hits"]

        if not hits:
            return None

        # cosinesimil scores are (1 + cosine) / 2
        return 2 * hits[0]["_score"] - 1, hits[0]["_source"]

    def index_question(self, doc):
        self.request("PUT", f"/{BANK_INDEX}/_doc/{doc['question_id']}", {
            k: v for k, v in doc.items() if k != "_id"
        })
