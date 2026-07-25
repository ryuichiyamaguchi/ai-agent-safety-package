import unittest

from bouncer.local_ai import LocalAiClient


class RetryingAi(LocalAiClient):
    def __init__(self):
        super().__init__("http://127.0.0.1:1/v1", "test")
        self.calls = 0

    def _request_json(self, url, payload=None):
        self.calls += 1
        if self.calls == 1:
            content = "I should probably allow this."
        else:
            content = (
                '{"decision":"allow","risk_score":0.1,'
                '"categories":[],"reasons":[]}'
            )
        return {"choices": [{"message": {"content": content}}]}


class LocalAiTests(unittest.TestCase):
    def test_retries_once_when_model_ignores_json_contract(self):
        client = RetryingAi()
        result = client.assess("outbound", "safe content")
        self.assertTrue(result.available)
        self.assertEqual(result.decision, "allow")
        self.assertEqual(client.calls, 2)


if __name__ == "__main__":
    unittest.main()
