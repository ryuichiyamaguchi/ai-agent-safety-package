import unittest

from bouncer.masking import MaskingSession


class MaskingSessionTests(unittest.TestCase):
    def test_masks_and_restores_multiple_sensitive_values(self) -> None:
        original = (
            "api_key=sk-ant-abcdefghijklmnopqrstuvwxyz123456 "
            "email=user@example.com path=/Users/ryuichi/project"
        )
        session = MaskingSession()

        masked = session.mask_text(original)

        self.assertNotIn("sk-ant-abcdefghijklmnopqrstuvwxyz123456", masked)
        self.assertNotIn("user@example.com", masked)
        self.assertNotIn("/Users/ryuichi", masked)
        self.assertIn("⟪BNC_", masked)
        self.assertEqual(session.restore_text(masked), original)
        self.assertGreaterEqual(session.masked_count, 3)

    def test_same_value_uses_same_placeholder(self) -> None:
        session = MaskingSession()
        masked = session.mask_text("user@example.com and user@example.com")
        tokens = [part for part in masked.split() if "BNC_" in part]
        self.assertEqual(tokens[0], tokens[-1])
        self.assertEqual(session.masked_count, 1)

    def test_masks_nested_json_without_changing_shape(self) -> None:
        session = MaskingSession()
        payload = {
            "messages": [
                {"role": "user", "content": "password=secret-value-123"}
            ],
            "stream": True,
        }
        masked = session.mask_value(payload)
        self.assertTrue(masked["stream"])
        self.assertNotIn("secret-value-123", masked["messages"][0]["content"])
        self.assertEqual(session.restore_value(masked), payload)


if __name__ == "__main__":
    unittest.main()
