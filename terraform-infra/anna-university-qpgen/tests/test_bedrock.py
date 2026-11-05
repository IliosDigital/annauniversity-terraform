import unittest
from unittest import mock

import support  # noqa: F401
from botocore.exceptions import ClientError

from common import bedrock

TOOL = {"toolSpec": {"name": "submit_questions", "description": "d", "inputSchema": {"json": {"type": "object"}}}}
ANSWER = {"output": {"message": {"content": [{"toolUse": {"toolUseId": "t", "name": "submit_questions",
                                                           "input": {"questions": []}}}]}},
          "usage": {"inputTokens": 5, "outputTokens": 3}}


def refusal():
    return ClientError({"Error": {"Code": "ValidationException",
                                  "Message": 'tool_choice: type "tool" and "any" are not supported for this model.'}},
                       "Converse")


class FakeClient:
    def __init__(self, *results):
        self.results, self.choices = list(results), []

    def converse(self, **params):
        self.choices.append(params["toolConfig"]["toolChoice"])
        result = self.results.pop(0)

        if isinstance(result, Exception):
            raise result

        return result


class ConverseToolTests(unittest.TestCase):
    def setUp(self):
        bedrock._forced_tool_refused.clear()
        self.addCleanup(bedrock._forced_tool_refused.clear)

    def call(self, client):
        with mock.patch.object(bedrock, "_client", return_value=client):
            return bedrock.converse_tool("system", "user", TOOL)

    def test_forced_tool_choice_is_tried_first(self):
        client = FakeClient(ANSWER)
        answer, usage = self.call(client)
        self.assertEqual(client.choices, [{"tool": {"name": "submit_questions"}}])
        self.assertEqual((answer, usage["inputTokens"]), ({"questions": []}, 5))

    def test_a_model_that_refuses_forced_tools_is_retried_with_auto_and_remembered(self):
        client = FakeClient(refusal(), ANSWER, ANSWER)
        self.call(client)
        self.assertEqual(client.choices, [{"tool": {"name": "submit_questions"}}, {"auto": {}}])
        self.call(client)  # remembered: no second refusal round trip
        self.assertEqual(client.choices[-1], {"auto": {}})
        self.assertEqual(len(client.choices), 3)

    def test_other_errors_are_not_swallowed(self):
        other = ClientError({"Error": {"Code": "ThrottlingException", "Message": "slow down"}}, "Converse")

        with self.assertRaises(ClientError):
            self.call(FakeClient(other))

    def test_a_reply_without_the_tool_call_becomes_an_empty_answer(self):
        text_only = {"output": {"message": {"content": [{"text": "Sure!"}]}}}
        self.assertEqual(self.call(FakeClient(text_only))[0], {})


if __name__ == "__main__":
    unittest.main()
