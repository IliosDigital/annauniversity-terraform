"""Structured logging. Log identifiers and counts, never prompts, textbook text
or question content."""
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def log(event, **fields):
    logger.info(json.dumps({"event": event, **fields}, default=str))


def log_error(event, **fields):
    logger.error(json.dumps({"event": event, **fields}, default=str), exc_info=True)
