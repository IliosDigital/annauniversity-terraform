import json
import unittest
from unittest import mock

import support
from support import PAGES, UNITS, FakeTextract, add_textbook, install

from common import documents, registry
from ingest import handler as ingest

TB = "a" * 32


def s3_event(key=None, version_id="ver-1", reprocess_id=None):
    key = key or f"textbooks/{TB}/v1/book.docx"
    detail = {"bucket": {"name": "tb-bucket"}, "object": {"key": key, "version-id": version_id}}

    if reprocess_id:
        detail["reprocess_id"] = reprocess_id

    return {"source": "aws.s3", "detail": {**detail}}


def docx_bytes():
    blocks = []

    for number, text in PAGES:
        blocks += [("para", text), ("pagebreak", "")]

    return documents.write_docx(blocks)


class IngestTestCase(unittest.TestCase):
    def setUp(self):
        self.fakes = install(self, [ingest])
        add_textbook(self.fakes, status="PENDING_UPLOAD")
        self.fakes.s3.put_object("tb-bucket", f"textbooks/{TB}/v1/book.docx", docx_bytes())

    def status(self):
        return registry.get_textbook(TB, "v1")

    def run_event(self, event=None):
        ingest.process(event or s3_event(), lambda: 900_000)


class HappyPathTests(IngestTestCase):
    def test_docx_is_extracted_chunked_embedded_and_indexed(self):
        self.run_event()
        textbook = self.status()
        self.assertEqual(textbook["status"], "COMPLETED")
        self.assertGreater(textbook["chunk_count"], 0)
        self.assertEqual(textbook["chunk_count"], len(self.fakes.search.chunks))
        self.assertEqual({c["unit"] for c in self.fakes.search.chunks.values()}, {1, 2})
        self.assertTrue(all(len(c["embedding"]) == 32 for c in self.fakes.search.chunks.values()))
        self.assertIn(("art-bucket", f"processed/{TB}/v1/chunks.json"), self.fakes.s3.objects)
        self.assertIn(("art-bucket", f"intermediate/{TB}/v1/pages.json"), self.fakes.s3.objects)

    def test_a_repeated_event_does_not_index_twice(self):
        self.run_event()
        self.run_event()
        self.assertEqual(self.fakes.search.bulk_calls, 1)

    def test_reprocessing_replaces_the_old_chunks(self):
        self.run_event()
        before = set(self.fakes.search.chunks)
        self.fakes.search.chunks["stale"] = {"textbook_id": TB, "version": "v1", "unit": 1, "embedding": [0]}
        self.run_event(s3_event(version_id=None, reprocess_id="r1"))  # as the API sends it
        self.assertEqual(set(self.fakes.search.chunks), before)
        self.assertEqual(self.status()["status"], "COMPLETED")

    def test_pdf_goes_through_textract_and_resumes_the_same_job(self):
        self.fakes.table.items[(f"TEXTBOOK#{TB}", "VERSION#v1")]["s3_key"] = f"textbooks/{TB}/v1/book.pdf"
        self.fakes.s3.put_object("tb-bucket", f"textbooks/{TB}/v1/book.pdf", b"%PDF-1.7\n...")
        self.fakes.textract.pages = PAGES
        self.run_event(s3_event(key=f"textbooks/{TB}/v1/book.pdf"))
        self.assertEqual(self.status()["status"], "COMPLETED")
        self.assertEqual(len(self.fakes.textract.started), 1)
        self.assertEqual({c["page"] for c in self.fakes.search.chunks.values()}, {1, 2, 3, 4})


class RejectionTests(IngestTestCase):
    def test_wrong_content_is_rejected_even_with_a_pdf_name(self):
        self.fakes.s3.put_object("tb-bucket", f"textbooks/{TB}/v1/fake.pdf", b"MZ\x90\x00 not a pdf")
        self.run_event(s3_event(key=f"textbooks/{TB}/v1/fake.pdf"))
        textbook = self.status()
        self.assertEqual((textbook["status"], textbook["error_code"]), ("FAILED", "UNSUPPORTED_FILE"))
        self.assertEqual(self.fakes.search.chunks, {})

    def test_oversized_file_is_rejected(self):
        with mock.patch.dict("os.environ", {"MAX_UPLOAD_MB": "0"}):
            self.run_event()

        self.assertEqual(self.status()["error_code"], "FILE_SIZE")

    def test_empty_extraction_fails_with_a_reason(self):
        self.fakes.s3.put_object("tb-bucket", f"textbooks/{TB}/v1/book.docx",
                                 documents.write_docx([("para", "tiny")]))
        self.run_event()
        self.assertEqual(self.status()["error_code"], "EMPTY_TEXT")

    def test_text_outside_every_unit_range_fails(self):
        self.fakes.table.items[(f"TEXTBOOK#{TB}", "VERSION#v1")]["units"] = [
            {"unit": 1, "title": "Far away", "start_page": 500, "end_page": 600}]
        self.run_event()
        self.assertEqual(self.status()["error_code"], "NO_CHUNKS")

    def test_unregistered_or_foreign_objects_are_ignored(self):
        self.run_event(s3_event(key="textbooks/" + "f" * 32 + "/v1/book.docx"))
        self.run_event(s3_event(key="other/place/book.docx"))
        self.assertEqual(self.status()["status"], "PENDING_UPLOAD")


class RetryTests(IngestTestCase):
    def test_transient_failure_releases_the_claim_and_can_be_retried(self):
        with mock.patch("common.bedrock.embed_many", side_effect=RuntimeError("throttled")):
            with self.assertRaises(RuntimeError):
                self.run_event()

        self.assertEqual(self.status()["status"], "UPLOADED")
        self.run_event()
        self.assertEqual(self.status()["status"], "COMPLETED")

    def test_handler_reports_failures_and_marks_failed_on_the_last_receive(self):
        def record(receives):
            return {"Records": [{"messageId": "m1", "body": json.dumps(s3_event()),
                                 "attributes": {"ApproximateReceiveCount": str(receives)}}]}

        context = mock.Mock(get_remaining_time_in_millis=lambda: 900_000)

        with mock.patch("common.bedrock.embed_many", side_effect=RuntimeError("boom")):
            first = ingest.lambda_handler(record(1), context)
            self.assertEqual(first["batchItemFailures"], [{"itemIdentifier": "m1"}])
            self.assertEqual(self.status()["status"], "UPLOADED")
            last = ingest.lambda_handler(record(3), context)

        self.assertEqual(last["batchItemFailures"], [{"itemIdentifier": "m1"}])
        self.assertEqual((self.status()["status"], self.status()["error_code"]), ("FAILED", "PROCESSING_ERROR"))


if __name__ == "__main__":
    unittest.main()
