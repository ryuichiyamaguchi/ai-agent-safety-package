import unittest
from dataclasses import replace

from bouncer.config import Config


class ConfigTests(unittest.TestCase):
    def test_default_upstream_is_allowed(self):
        Config().validate()

    def test_custom_upstream_requires_explicit_opt_in(self):
        config = replace(Config(), anthropic_upstream="https://proxy.example.com")
        with self.assertRaises(ValueError):
            config.validate()

    def test_plain_http_custom_upstream_must_be_loopback(self):
        local = replace(
            Config(),
            anthropic_upstream="http://127.0.0.1:9999",
            allow_custom_upstream=True,
        )
        local.validate()
        remote = replace(
            Config(),
            anthropic_upstream="http://192.0.2.1:9999",
            allow_custom_upstream=True,
        )
        with self.assertRaises(ValueError):
            remote.validate()


if __name__ == "__main__":
    unittest.main()
