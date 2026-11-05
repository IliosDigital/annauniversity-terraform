import json
import unittest

import support
from support import UNITS, add_textbook, install

from api import handler as api
from common import registry


def event(method, resource, body=None, groups="faculty", sub="user-1", path=None, query=None, headers=None):
    return {
        "httpMethod": method, "resource": resource,
        "body": json.dumps(body) if body is not None else None,
        "pathParameters": path, "queryStringParameters": query, "headers": headers or {},
        "requestContext": {"requestId": "req-1", "authorizer": {
            "claims": {"sub": sub, "email": f"{sub}@example.com", "cognito:groups": groups}}},
    }


def call(*args, **kwargs):
    response = api.lambda_handler(event(*args, **kwargs), None)
    return response["statusCode"], (json.loads(response["body"]) if response["body"] else None)


PAPER = {"textbook_id": "a" * 32, "version": "v1", "subject": "Machine Learning", "units": [1, 2],
         "difficulty": "Mixed", "count": 10}


class ApiTestCase(unittest.TestCase):
    def setUp(self):
        self.fakes = install(self, [api])


class TextbookTests(ApiTestCase):
    BODY = {"title": "ML", "subject": "Machine Learning", "version": "v1", "filename": "ml.pdf", "units": UNITS}

    def test_administrator_registers_a_textbook_and_gets_an_upload_form(self):
        status, body = call("POST", "/textbooks", self.BODY, groups="[administrator]")
        self.assertEqual(status, 201)
        self.assertEqual(body["status"], "PENDING_UPLOAD")
        self.assertTrue(body["upload"]["fields"]["key"].startswith(f"textbooks/{body['textbook_id']}/v1/"))
        self.assertEqual(body["upload"]["fields"]["Content-Type"], "application/pdf")

    def test_faculty_cannot_register_or_reprocess(self):
        self.assertEqual(call("POST", "/textbooks", self.BODY, groups="faculty")[0], 403)
        self.assertEqual(call("POST", "/textbooks/{textbook_id}/{version}/reprocess",
                              path={"textbook_id": "a" * 32, "version": "v1"}, groups="faculty")[0], 403)

    def test_users_without_a_group_are_refused(self):
        self.assertEqual(call("GET", "/textbooks", groups="")[0], 403)

    def test_bad_registrations_are_rejected(self):
        bad = {
            "exe file": {**self.BODY, "filename": "run.exe"},
            "path in filename": {**self.BODY, "filename": "../x.pdf"},
            "bad version": {**self.BODY, "version": "v 1/2"},
            "no units": {**self.BODY, "units": []},
            "reversed pages": {**self.BODY, "units": [{"unit": 1, "title": "A", "start_page": 9, "end_page": 2}]},
            "duplicate unit": {**self.BODY, "units": UNITS[:1] * 2},
            "missing title": {k: v for k, v in self.BODY.items() if k != "title"},
        }

        for label, body in bad.items():
            with self.subTest(label):
                self.assertEqual(call("POST", "/textbooks", body, groups="administrator")[0], 400)

    def test_list_and_get_show_status_without_internal_fields(self):
        textbook_id, version = add_textbook(self.fakes, status="COMPLETED")
        add_textbook(self.fakes, status="FAILED", textbook_id="b" * 32)
        _, listing = call("GET", "/textbooks")
        self.assertEqual(len(listing["textbooks"]), 2)
        _, completed = call("GET", "/textbooks", query={"status": "COMPLETED"})
        self.assertEqual([t["textbook_id"] for t in completed["textbooks"]], [textbook_id])
        status, one = call("GET", "/textbooks/{textbook_id}/{version}", path={"textbook_id": textbook_id, "version": version})
        self.assertEqual((status, one["status"]), (200, "COMPLETED"))
        self.assertNotIn("s3_key", one)
        self.assertEqual(call("GET", "/textbooks", query={"status": "BOGUS"})[0], 400)

    def test_reprocess_queues_a_message_for_completed_or_failed_only(self):
        textbook_id, version = add_textbook(self.fakes, status="COMPLETED")
        path = {"textbook_id": textbook_id, "version": version}
        status, _ = call("POST", "/textbooks/{textbook_id}/{version}/reprocess", path=path, groups="administrator")
        self.assertEqual(status, 202)
        queue, message = self.fakes.sqs.sent[-1]
        self.assertEqual(queue, "https://sqs/ingest")
        self.assertEqual(message["detail"]["object"]["key"], f"textbooks/{textbook_id}/{version}/book.docx")
        self.assertEqual(registry.get_textbook(textbook_id, version)["status"], "UPLOADED")
        again, _ = call("POST", "/textbooks/{textbook_id}/{version}/reprocess", path=path, groups="administrator")
        self.assertEqual(again, 409)


class PaperTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        add_textbook(self.fakes, status="COMPLETED")

    def test_request_creates_a_job_and_queues_generation(self):
        status, body = call("POST", "/question-papers", PAPER, headers={"X-Correlation-Id": "corr-9"})
        self.assertEqual((status, body["status"], body["correlation_id"]), (202, "ACCEPTED", "corr-9"))
        self.assertEqual(self.fakes.sqs.sent, [("https://sqs/generate", {"job_id": body["job_id"]})])
        job = registry.get_job(body["job_id"])
        self.assertEqual(job["request"]["units"], [1, 2])
        self.assertEqual(job["user"], "user-1")

    def test_only_completed_textbooks_are_eligible(self):
        for state in ("PENDING_UPLOAD", "UPLOADED", "PROCESSING", "FAILED"):
            with self.subTest(state):
                add_textbook(self.fakes, status=state, textbook_id=state.lower().ljust(32, "x")[:32])
                body = {**PAPER, "textbook_id": state.lower().ljust(32, "x")[:32]}
                self.assertEqual(call("POST", "/question-papers", body)[0], 409)

        self.assertEqual(self.fakes.sqs.sent, [])

    def test_request_is_checked_against_the_textbook(self):
        self.assertEqual(call("POST", "/question-papers", {**PAPER, "subject": "Physics"})[0], 400)
        self.assertEqual(call("POST", "/question-papers", {**PAPER, "units": [1, 7]})[0], 400)
        self.assertEqual(call("POST", "/question-papers", {**PAPER, "textbook_id": "c" * 32})[0], 404)

    def test_invalid_requests_are_rejected_before_anything_is_stored(self):
        bad = {
            "zero questions": {**PAPER, "count": 0},
            "too many questions": {**PAPER, "count": 101},
            "boolean count": {**PAPER, "count": True},
            "no units": {**PAPER, "units": []},
            "bad difficulty": {**PAPER, "difficulty": "Impossible"},
            "pdf output": {**PAPER, "formats": ["pdf"]},
            "answer key not boolean": {**PAPER, "include_answer_key": "yes"},
            "sections do not add up": {**PAPER, "sections": [{"name": "A", "count": 4, "marks": 2}]},
        }

        for label, body in bad.items():
            with self.subTest(label):
                self.assertEqual(call("POST", "/question-papers", body)[0], 400)

        self.assertEqual(self.fakes.sqs.sent, [])

    def test_sections_are_accepted_when_they_add_up(self):
        sections = [{"name": "Part A", "count": 6, "marks": 2}, {"name": "Part B", "count": 4, "marks": 5}]
        status, body = call("POST", "/question-papers", {**PAPER, "sections": sections})
        self.assertEqual(status, 202)
        self.assertEqual(registry.get_job(body["job_id"])["request"]["sections"], sections)

    def test_idempotency_key_prevents_a_second_job(self):
        headers = {"Idempotency-Key": "request-0001"}
        _, first = call("POST", "/question-papers", PAPER, headers=headers)
        status, second = call("POST", "/question-papers", PAPER, headers=headers)
        self.assertEqual((status, second["job_id"], second["replayed"]), (200, first["job_id"], True))
        self.assertEqual(len(self.fakes.sqs.sent), 1)
        self.assertEqual(call("POST", "/question-papers", PAPER, headers={"Idempotency-Key": "x"})[0], 400)

    def test_jobs_are_private_to_their_owner_and_administrators(self):
        _, job = call("POST", "/question-papers", PAPER, sub="owner")
        path = {"job_id": job["job_id"]}
        self.assertEqual(call("GET", "/question-papers/{job_id}", path=path, sub="owner")[0], 200)
        self.assertEqual(call("GET", "/question-papers/{job_id}", path=path, sub="stranger")[0], 404)
        self.assertEqual(call("GET", "/question-papers/{job_id}", path=path, sub="boss", groups="administrator")[0], 200)
        _, mine = call("GET", "/question-papers", sub="owner")
        self.assertEqual([j["job_id"] for j in mine["jobs"]], [job["job_id"]])
        self.assertEqual(call("GET", "/question-papers", sub="stranger")[1]["jobs"], [])

    def test_completed_job_returns_download_links(self):
        _, job = call("POST", "/question-papers", PAPER)
        registry.set_job_status(job["job_id"], ("ACCEPTED",), "PROCESSING")
        registry.set_job_status(job["job_id"], ("PROCESSING",), "COMPLETED",
                                outputs={"question_paper_docx": f"papers/{job['job_id']}/question-paper.docx"})
        _, view = call("GET", "/question-papers/{job_id}", path={"job_id": job["job_id"]})
        self.assertIn("question_paper_docx", view["downloads"])
        self.assertIn("out-bucket", view["downloads"]["question_paper_docx"])
        _, pending = call("POST", "/question-papers", PAPER)
        self.assertNotIn("downloads", call("GET", "/question-papers/{job_id}", path={"job_id": pending["job_id"]})[1])


class GeneralTests(ApiTestCase):
    def test_health_is_open_and_unknown_routes_404(self):
        self.assertEqual(call("GET", "/health", groups="")[0], 200)
        self.assertEqual(call("DELETE", "/textbooks")[0], 404)

    def test_malformed_json_and_path_ids(self):
        response = api.lambda_handler({**event("POST", "/question-papers"), "body": "{nope"}, None)
        self.assertEqual(response["statusCode"], 400)
        self.assertEqual(call("GET", "/question-papers/{job_id}", path={"job_id": "nope"})[0], 400)
        self.assertEqual(call("GET", "/textbooks/{textbook_id}/{version}",
                              path={"textbook_id": "zz", "version": "v1"})[0], 400)


if __name__ == "__main__":
    unittest.main()
