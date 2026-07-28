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

    def test_masks_secret_names_that_contain_underscores(self) -> None:
        """`\\b` is not a boundary at `_`, so these key names used to be missed."""
        session = MaskingSession()
        samples = {
            "AWS_SECRET_ACCESS_KEY": "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY",
            "MYSERVICE_API_KEY": "abc123def456ghi789",
            "STRIPE_KEY": "sk" + "_live_51H8xkLmNoPqRsTuVwXyZ",
            "DB-PASSWORD": "hunter2-hunter2",
            "client_secret": "6f1b9c2d4e8a0b3c",
            "SESSION_TOKEN": "eyJhbGciOiJIUzI1NiJ9abcdef",
        }
        for name, value in samples.items():
            with self.subTest(name=name):
                masked = session.mask_text(f"{name}={value}")
                self.assertNotIn(value, masked)
                self.assertIn("⟪BNC_", masked)
                self.assertEqual(session.restore_text(masked), f"{name}={value}")

    def test_masks_secret_names_in_json_and_yaml_shapes(self) -> None:
        session = MaskingSession()
        original = (
            '{"aws_secret_access_key": "wJalrXUtnFEMIK7MDENGbPxRfiCY"}\n'
            "MYSERVICE_API_KEY: abc123def456ghi789\n"
        )
        masked = session.mask_text(original)
        self.assertNotIn("wJalrXUtnFEMIK7MDENGbPxRfiCY", masked)
        self.assertNotIn("abc123def456ghi789", masked)
        self.assertEqual(session.restore_text(masked), original)

    def test_ordinary_words_are_not_treated_as_secret_names(self) -> None:
        session = MaskingSession()
        original = (
            "monkey=banana-split-1\n"
            "key: 押しても動きません\n"
            "keyboard=mechanical-blue\n"
            "turkey = roasted-slowly\n"
            "SECRET_KEY = get_random_secret_key()\n"
        )
        masked = session.mask_text(original)
        self.assertEqual(masked, original)
        self.assertEqual(session.masked_count, 0)

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
