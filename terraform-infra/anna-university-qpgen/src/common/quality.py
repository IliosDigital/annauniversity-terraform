"""Quality gates for a generated question paper. Pure functions, no AWS.

The first checks follow the rules of the prototype validator shown in the
evidence package (count, empty text, exact duplicates, subject, unit,
difficulty). The rest add source traceability and semantic duplicates.
"""
import hashlib
import math
import re

DIFFICULTIES = ("Easy", "Medium", "Hard")
MIN_QUESTION_CHARS = 10
MAX_QUESTION_CHARS = 1500


def normalize(text):
    """Collapse whitespace, casefold and drop trailing punctuation."""
    return re.sub(r"\s+", " ", str(text or "")).strip().casefold().rstrip(" .?!;:")


def question_hash(text):
    return hashlib.sha256(normalize(text).encode("utf-8")).hexdigest()


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    norm = math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b))
    return dot / norm if norm else 0.0


def check_questions(questions, allowed_subject, allowed_units=None, retrieved_ids=None):
    """Per-question problems, as {index: [message, ...]} with 1-based indexes.

    retrieved_ids, when given, is the set of passage ids the model was shown;
    every question must cite at least one of them.
    """
    problems = {}
    seen = set()

    def add(idx, message):
        problems.setdefault(idx, []).append(message)

    for idx, item in enumerate(questions, start=1):
        if not isinstance(item, dict):
            add(idx, f"question {idx} must be an object")
            continue

        text = normalize(item.get("question"))

        if not text:
            add(idx, f"question {idx} has empty question text")
        elif not MIN_QUESTION_CHARS <= len(str(item["question"]).strip()) <= MAX_QUESTION_CHARS:
            add(idx, f"question {idx} length is outside {MIN_QUESTION_CHARS}-{MAX_QUESTION_CHARS} characters")

        if text and text in seen:
            add(idx, f"question {idx} is a duplicate")

        seen.add(text)

        if item.get("subject") != allowed_subject:
            add(idx, f"question {idx} subject does not match requested subject")

        if allowed_units is not None and item.get("unit") not in allowed_units:
            add(idx, f"question {idx} unit is not one of the selected units")

        if item.get("difficulty") not in DIFFICULTIES:
            add(idx, f"question {idx} difficulty must be Easy, Medium or Hard")

        if retrieved_ids is not None:
            sources = item.get("source_chunk_ids")

            if not isinstance(sources, list) or not sources or not set(sources) <= set(retrieved_ids):
                add(idx, f"question {idx} does not cite a retrieved source passage")

    return problems


def validate_question_paper(questions, requested_count, allowed_subject, allowed_units=None):
    """Flat list of issue messages; an empty list means the paper passes."""
    if not isinstance(questions, list):
        return ["questions must be a list"]

    issues = []

    if len(questions) != requested_count:
        issues.append(f"expected {requested_count} questions, received {len(questions)}")

    for messages in check_questions(questions, allowed_subject, allowed_units).values():
        issues.extend(messages)

    return issues


def near_duplicate_indexes(vectors, threshold):
    """Indexes (0-based) of questions too similar to an earlier one in the paper."""
    rejected = set()

    for i in range(len(vectors)):
        for j in range(i):
            if j not in rejected and cosine(vectors[i], vectors[j]) >= threshold:
                rejected.add(i)
                break

    return sorted(rejected)
