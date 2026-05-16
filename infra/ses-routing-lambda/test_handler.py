import unittest
from unittest import mock

import handler


SAMPLE_ROUTED = (
    b"Return-Path: <noreply@openrouter.ai>\r\n"
    b"Received: from foo.example.com (foo.example.com [192.0.2.1])\r\n"
    b"  by inbound-smtp.us-east-1.amazonaws.com\r\n"
    b"From: OpenRouter <notifications@openrouter.ai>\r\n"
    b"To: or-0xca7794ab45690d40fa791d738c715052445109aa-1778821613@bots.litentry.org\r\n"
    b"Subject: Your sign up link\r\n"
    b"\r\n"
    b"<body truncated for header-only test>"
)

SAMPLE_AGENTKEYS_AUTH = (
    b"From: AgentKeys <noreply@agentkeys.test>\r\n"
    b"To: demo-1@bots.litentry.org\r\n"
    b"Subject: Verify your email\r\n"
    b"\r\n"
    b"<body>"
)

SAMPLE_DISPLAY_NAME = (
    b"From: foo\r\n"
    b'To: "Operator Alice" <or-0xCA7794ab45690d40fa791d738c715052445109AA-1778821613@bots.litentry.org>\r\n'
    b"Subject: x\r\n\r\nb"
)


class ExtractTests(unittest.TestCase):
    def test_routed_recipient_extracted(self):
        local_part = handler._extract_to_local_part(SAMPLE_ROUTED)
        self.assertEqual(
            local_part,
            "or-0xca7794ab45690d40fa791d738c715052445109aa-1778821613",
        )
        m = handler.WALLET_LOCAL_PART_RE.match(local_part)
        self.assertIsNotNone(m)
        self.assertEqual(m.group(1).lower(), "0xca7794ab45690d40fa791d738c715052445109aa")

    def test_agentkeys_auth_skipped(self):
        local_part = handler._extract_to_local_part(SAMPLE_AGENTKEYS_AUTH)
        self.assertEqual(local_part, "demo-1")
        self.assertIsNone(handler.WALLET_LOCAL_PART_RE.match(local_part))

    def test_display_name_form_handled(self):
        local_part = handler._extract_to_local_part(SAMPLE_DISPLAY_NAME)
        self.assertTrue(local_part.startswith("or-0xca7794ab"))
        # Case-folded to lower in extractor.
        self.assertNotIn("CA7794", local_part)


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.s3 = mock.Mock()
        # _client() returns whatever handler._s3 is set to. Inject a mock.
        handler._s3 = self.s3

    def tearDown(self):
        handler._s3 = None

    def test_routes_matching_email(self):
        self.s3.get_object.return_value = {
            "Body": mock.Mock(read=mock.Mock(return_value=SAMPLE_ROUTED))
        }
        outcome = handler._route_one("test-bucket", "inbound/msg123")
        self.assertEqual(outcome, "routed")
        self.s3.copy_object.assert_called_once()
        kwargs = self.s3.copy_object.call_args.kwargs
        self.assertEqual(
            kwargs["Key"],
            "bots/0xca7794ab45690d40fa791d738c715052445109aa/inbound/msg123",
        )
        self.assertEqual(kwargs["CopySource"]["Key"], "inbound/msg123")

    def test_skips_agentkeys_auth_email(self):
        self.s3.get_object.return_value = {
            "Body": mock.Mock(read=mock.Mock(return_value=SAMPLE_AGENTKEYS_AUTH))
        }
        outcome = handler._route_one("test-bucket", "inbound/msg456")
        self.assertEqual(outcome, "skipped")
        self.s3.copy_object.assert_not_called()

    def test_skips_non_inbound_key(self):
        outcome = handler._route_one("test-bucket", "bots/0xfoo/inbound/msg789")
        self.assertEqual(outcome, "skipped")
        self.s3.get_object.assert_not_called()
        self.s3.copy_object.assert_not_called()


class HandlerEventTests(unittest.TestCase):
    def test_handler_counts(self):
        event = {
            "Records": [
                {"s3": {"bucket": {"name": "b"}, "object": {"key": "inbound/m1"}}},
                {"s3": {"bucket": {"name": "b"}, "object": {"key": "inbound/m2"}}},
                {"s3": {"bucket": {"name": "b"}, "object": {"key": "bots/foo/m3"}}},
            ]
        }
        with mock.patch.object(handler, "_route_one") as r:
            r.side_effect = ["routed", "skipped", "skipped"]
            result = handler.handler(event, None)
            self.assertEqual(result, {"routed": 1, "skipped": 2})


if __name__ == "__main__":
    unittest.main()
