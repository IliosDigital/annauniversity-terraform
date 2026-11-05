import unittest

import support  # noqa: F401

from common import chunking, documents, quality


class PrototypeRuleTests(unittest.TestCase):
    """The five cases of the prototype validator in the evidence package."""

    def test_valid_questions_pass(self):
        questions = [
            {"question": "Explain supervised learning.", "subject": "Machine Learning", "unit": 1, "difficulty": "Easy"},
            {"question": "Compare bagging and boosting.", "subject": "Machine Learning", "unit": 2, "difficulty": "Medium"},
        ]
        self.assertEqual(quality.validate_question_paper(questions, 2, "Machine Learning", {1, 2}), [])

    def test_duplicate_questions_are_flagged(self):
        question = {"question": "Define entropy.", "subject": "AI", "unit": 1, "difficulty": "Easy"}
        issues = quality.validate_question_paper([question, dict(question)], 2, "AI", {1})
        self.assertTrue(any("duplicate" in issue for issue in issues))

    def test_wrong_count_and_unselected_unit_are_flagged(self):
        questions = [{"question": "Describe a neural network.", "subject": "AI", "unit": 3, "difficulty": "Hard"}]
        issues = quality.validate_question_paper(questions, 2, "AI", {1, 2})
        self.assertTrue(any("expected 2 questions" in i for i in issues))
        self.assertTrue(any("unit" in i for i in issues))

    def test_empty_text_wrong_subject_and_bad_difficulty(self):
        questions = [{"question": "  ", "subject": "Maths", "unit": 1, "difficulty": "Easy"},
                     {"question": "Describe a neural network.", "subject": "AI", "unit": 1, "difficulty": "Tricky"}]
        issues = quality.validate_question_paper(questions, 2, "AI", {1})
        self.assertTrue(any("empty" in i for i in issues))
        self.assertTrue(any("subject" in i for i in issues))
        self.assertTrue(any("difficulty" in i for i in issues))

    def test_non_list_input(self):
        self.assertEqual(quality.validate_question_paper("x", 1, "AI"), ["questions must be a list"])


class ExtraGateTests(unittest.TestCase):
    def test_duplicates_ignore_case_spacing_and_trailing_punctuation(self):
        self.assertEqual(quality.question_hash("Define  Entropy?"), quality.question_hash("define entropy"))

    def test_questions_must_cite_retrieved_sources(self):
        good = {"question": "Explain bagging in detail.", "subject": "ML", "unit": 1, "difficulty": "Easy",
                "source_chunk_ids": ["c1"]}
        bad = {**good, "question": "Explain boosting in detail.", "source_chunk_ids": ["invented"]}
        none = {**good, "question": "Explain stacking in detail.", "source_chunk_ids": []}
        problems = quality.check_questions([good, bad, none], "ML", {1}, retrieved_ids={"c1"})
        self.assertEqual(sorted(problems), [2, 3])

    def test_near_duplicate_indexes_keep_the_first(self):
        vectors = [[1, 0], [0.99, 0.05], [0, 1]]
        self.assertEqual(quality.near_duplicate_indexes(vectors, 0.95), [1])


class ChunkingTests(unittest.TestCase):
    def test_chunks_carry_unit_page_and_stable_ids(self):
        first = chunking.chunk_pages(support.PAGES, support.UNITS, "tb", "v1")
        again = chunking.chunk_pages(support.PAGES, support.UNITS, "tb", "v1")
        self.assertEqual([c["chunk_id"] for c in first], [c["chunk_id"] for c in again])
        self.assertEqual({c["unit"] for c in first}, {1, 2})
        self.assertTrue(all(len(c["text"]) <= chunking.MAX_CHARS for c in first))
        self.assertEqual({c["page"] for c in first if c["unit"] == 2}, {3, 4})

    def test_pages_outside_every_unit_are_dropped(self):
        pages = support.PAGES + [(9, "Appendix text that belongs to no unit at all. " * 5)]
        self.assertNotIn(9, {c["page"] for c in chunking.chunk_pages(pages, support.UNITS, "tb", "v1")})

    def test_running_headers_are_removed(self):
        pages = [(n, f"Machine Learning Textbook\nBody text of page {n} " + "word " * 40) for n in range(1, 7)]
        units = [{"unit": 1, "title": "All", "start_page": 1, "end_page": 6}]
        text = " ".join(c["text"] for c in chunking.chunk_pages(pages, units, "tb", "v1"))
        self.assertNotIn("Machine Learning Textbook", text)

    def test_long_page_is_split_with_overlap(self):
        page = [(1, ". ".join(f"Sentence number {i} about learning" for i in range(200)))]
        units = [{"unit": 1, "title": "All", "start_page": 1, "end_page": 1}]
        chunks = chunking.chunk_pages(page, units, "tb", "v1")
        self.assertGreater(len(chunks), 2)
        self.assertTrue(all(len(c["text"]) <= chunking.MAX_CHARS for c in chunks))


class DocumentTests(unittest.TestCase):
    def test_docx_round_trip(self):
        data = documents.write_docx([("title", "Paper"), ("para", "Q1. What is <overfitting> & why?")])
        self.assertEqual(documents.sniff(data), "docx")
        pages = documents.read_docx_pages(data)
        self.assertIn("What is <overfitting> & why?", pages[0][1])

    def test_generated_docx_opens_in_python_docx(self):
        try:
            import docx
        except ImportError:
            self.skipTest("python-docx not installed")

        import io
        text = [p.text for p in docx.Document(io.BytesIO(documents.write_docx([("title", "T"), ("para", "Body")]))).paragraphs]
        self.assertEqual(text, ["T", "Body"])

    def test_sniff_uses_content_not_name(self):
        self.assertEqual(documents.sniff(b"%PDF-1.7 ..."), "pdf")
        self.assertIsNone(documents.sniff(b"MZ\x90\x00"))
        self.assertIsNone(documents.sniff(b"PK\x03\x04 not really a zip"))

    def test_explicit_page_breaks_are_respected(self):
        data = documents.write_docx([("para", "first page"), ("pagebreak", ""), ("para", "second page")])
        self.assertEqual(documents.read_docx_pages(data), [(1, "first page"), (2, "second page")])

    def test_without_page_breaks_pages_are_synthesised(self):
        data = documents.write_docx([("para", "x" * 2000), ("para", "y" * 2000), ("para", "z" * 100)])
        self.assertEqual(len(documents.read_docx_pages(data)), 2)


if __name__ == "__main__":
    unittest.main()
