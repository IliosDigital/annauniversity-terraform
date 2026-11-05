"""Cleaning and unit-aware chunking of extracted textbook pages. Pure functions."""
import hashlib
import re
from collections import Counter

MAX_CHARS = 1200
OVERLAP = 150
MIN_CHARS = 40


def normalize_whitespace(text):
    text = re.sub(r"-\n(?=[a-z])", "", text)  # re-join words hyphenated at line ends
    text = re.sub(r"[ \t ]+", " ", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def strip_repeated_lines(pages, share=0.6, max_len=80):
    """Drop running headers and footers: short lines that repeat on most pages."""
    if len(pages) < 4:
        return pages

    counts = Counter()

    for _, text in pages:
        counts.update({line.strip() for line in text.splitlines() if 0 < len(line.strip()) <= max_len})

    repeated = {line for line, n in counts.items() if n >= share * len(pages)}

    return [
        (number, "\n".join(l for l in text.splitlines() if l.strip() not in repeated))
        for number, text in pages
    ]


def unit_for_page(units, page):
    for unit in units:
        if unit["start_page"] <= page <= unit["end_page"]:
            return unit["unit"]

    return None


def _windows(text):
    """Split one page into overlapping windows, preferring paragraph breaks."""
    if len(text) <= MAX_CHARS:
        return [text]

    windows, start = [], 0

    while start < len(text):
        end = min(start + MAX_CHARS, len(text))

        if end < len(text):
            cut = max(text.rfind("\n\n", start, end), text.rfind(". ", start, end))

            if cut > start + MAX_CHARS // 2:
                end = cut + 1

        windows.append(text[start:end].strip())

        if end >= len(text):
            break

        start = max(end - OVERLAP, start + 1)

    return windows


def chunk_pages(pages, units, textbook_id, version):
    """Chunks with stable ids. A page outside every unit range is skipped, so
    nothing unassigned can ever be retrieved for a paper."""
    chunks = []

    for number, raw in strip_repeated_lines(pages):
        unit = unit_for_page(units, number)
        text = normalize_whitespace(raw)

        if unit is None or not text:
            continue

        for position, piece in enumerate(_windows(text)):
            if len(piece) < MIN_CHARS:
                continue

            digest = hashlib.sha256(
                f"{textbook_id}|{version}|{number}|{position}|{piece}".encode("utf-8")
            ).hexdigest()
            chunks.append({
                "chunk_id": digest[:32],
                "textbook_id": textbook_id,
                "version": version,
                "unit": unit,
                "page": number,
                "text": piece,
            })

    return chunks
