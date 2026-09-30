"""Offline enrollment tests. All identities are synthetic; no real API is called."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock
import urllib.parse


CLOUD = Path(__file__).resolve().parents[1]
BRIDGE_SPEC = importlib.util.spec_from_file_location("enrollment_bridge_under_test", CLOUD / "bridge.py")
bridge = importlib.util.module_from_spec(BRIDGE_SPEC)
BRIDGE_SPEC.loader.exec_module(bridge)
ENROLL_SPEC = importlib.util.spec_from_file_location("enrollment_under_test", CLOUD / "enroll.py")
enroll = importlib.util.module_from_spec(ENROLL_SPEC)
with mock.patch.dict(sys.modules, {"bridge": bridge}):
    ENROLL_SPEC.loader.exec_module(enroll)


def qr():
    return {"qrcode": "synthetic-qr-id", "qrcode_img_content": "synthetic-qr-content"}


def confirmed(**changes):
    value = {"status": "confirmed", "bot_token": "synthetic-wechat-token",
             "ilink_bot_id": "synthetic-account", "ilink_user_id": "synthetic-owner",
             "baseurl": "https://ilinkai.weixin.qq.com"}
    value.update(changes)
    return value


def credentials():
    return {key: value for key, value in confirmed().items() if key != "status"}


class ScriptedHTTP:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def request(self, url, headers, body=None, timeout=45):
        self.calls.append((url, dict(headers), body, timeout))
        if not self.responses:
            raise AssertionError("Unexpected request after scripted responses exhausted")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


class EnrollmentTests(unittest.TestCase):
    def run_flow(self, responses, verify="123456", approve=True):
        self.http = ScriptedHTTP(responses)
        self.render = mock.Mock()
        self.verify = mock.Mock(return_value=verify)
        self.confirm = mock.Mock(return_value=approve)
        self.sleep = mock.Mock()
        return enroll.Enrollment(self.http, self.render, self.verify, self.confirm, self.sleep).run()

    def test_wait_scan_and_confirm_are_read_only_until_owner_approval(self):
        result = self.run_flow([qr(), {"status": "wait"}, {"status": "scaned"}, confirmed()])
        self.assertEqual(result, credentials())
        self.render.assert_called_once_with("synthetic-qr-content")
        self.verify.assert_not_called()
        self.confirm.assert_called_once_with("synthetic-owner")
        self.assertEqual(self.sleep.call_count, 2)
        self.assertEqual(self.http.calls[0][2], {"local_token_list": []})
        encoded_uin = self.http.calls[0][1]["X-WECHAT-UIN"]
        self.assertTrue(base64.b64decode(encoded_uin, validate=True).decode().isdigit())
        self.assertTrue(self.http.calls[0][0].endswith("/get_bot_qrcode?bot_type=3"))
        self.assertTrue(all(call[2] is None for call in self.http.calls[1:]))
        self.assertTrue(all("Authorization" not in call[1] for call in self.http.calls))

    def test_verification_code_is_encoded_on_next_status_request_only(self):
        self.run_flow([qr(), {"status": "need_verifycode"}, {"status": "wait"}, confirmed()],
                      verify="  12+34&56  ")
        queries = [urllib.parse.parse_qs(urllib.parse.urlsplit(call[0]).query)
                   for call in self.http.calls[1:]]
        self.assertNotIn("verify_code", queries[0])
        self.assertEqual(queries[1]["verify_code"], ["12+34&56"])
        self.assertNotIn("verify_code", queries[2])
        self.verify.assert_called_once_with()

    def test_missing_or_oversize_verification_code_fails_closed(self):
        for code in ("", "   ", "x" * 65):
            with self.subTest(code_length=len(code)), self.assertRaises(bridge.SafeError):
                self.run_flow([qr(), {"status": "need_verifycode"}], verify=code)
            self.confirm.assert_not_called()

    def test_expired_qr_is_replaced_and_rendered_again(self):
        self.assertEqual(self.run_flow([qr(), {"status": "expired"}, qr(), confirmed()]), credentials())
        self.assertEqual(self.render.call_count, 2)

    def test_repeated_expiry_is_bounded_at_four_qrs(self):
        responses = [item for _ in range(4) for item in (qr(), {"status": "expired"})]
        with self.assertRaisesRegex(bridge.SafeError, "repeatedly expired"):
            self.run_flow(responses)
        self.assertEqual(self.render.call_count, 4)
        self.assertEqual(len(self.http.calls), 8)

    def test_blocked_bound_unknown_and_missing_status_are_rejected(self):
        for status in ("verify_code_blocked", "binded_redirect", "new-unsupported-status", None):
            with self.subTest(status=status), self.assertRaises(bridge.SafeError):
                self.run_flow([qr(), {"status": status}])
            self.confirm.assert_not_called()

    def test_bad_qr_values_are_rejected_before_rendering(self):
        for key in ("qrcode", "qrcode_img_content"):
            for value in (None, "", 123, [], "x" * 4097):
                response = qr()
                response[key] = value
                with self.subTest(key=key, value_type=type(value)), self.assertRaises(bridge.SafeError):
                    self.run_flow([response])
                self.render.assert_not_called()

    def test_trusted_redirect_changes_only_the_polling_endpoint(self):
        response = {"status": "scaned_but_redirect", "redirect_host": "regional.wechat.com"}
        result = self.run_flow([qr(), response, confirmed(baseurl="regional.wechat.com")])
        self.assertTrue(self.http.calls[2][0].startswith("https://regional.wechat.com/ilink/bot/get_qrcode_status?"))
        self.assertEqual(result["baseurl"], "https://regional.wechat.com")

    def test_untrusted_or_malformed_redirect_is_rejected_without_following(self):
        for host in ("attacker.example", "weixin.qq.com.attacker.example", "wechat.com.attacker.example",
                     "name:password@regional.wechat.com", "regional.wechat.com:8443",
                     "regional.wechat.com/path", "regional.wechat.com?q=secret", None):
            with self.subTest(host=host), self.assertRaises(bridge.SafeError):
                self.run_flow([qr(), {"status": "scaned_but_redirect", "redirect_host": host}])
            self.assertEqual(len(self.http.calls), 2)

    def test_redirect_count_is_bounded(self):
        response = {"status": "scaned_but_redirect", "redirect_host": "regional.wechat.com"}
        with self.assertRaisesRegex(bridge.SafeError, "Too many"):
            self.run_flow([qr()] + [response] * 4)
        self.assertEqual(len(self.http.calls), 5)

    def test_confirmed_missing_owner_never_uses_first_inbound_message(self):
        response = confirmed()
        del response["ilink_user_id"]
        with self.assertRaisesRegex(bridge.SafeError, "owner ID"):
            self.run_flow([qr(), response])
        self.confirm.assert_not_called()

    def test_confirmed_missing_or_invalid_credentials_are_rejected(self):
        for field, limit in (("bot_token", 65536), ("ilink_bot_id", 4096), ("ilink_user_id", 4096)):
            for value in (None, "", 123, "x" * (limit + 1)):
                with self.subTest(field=field, value_type=type(value)), self.assertRaises(bridge.SafeError):
                    self.run_flow([qr(), confirmed(**{field: value})])
                self.confirm.assert_not_called()

    def test_owner_decline_returns_no_credentials(self):
        with self.assertRaisesRegex(bridge.SafeError, "confirmation declined"):
            self.run_flow([qr(), confirmed()], approve=False)
        self.confirm.assert_called_once_with("synthetic-owner")

    def test_confirmed_untrusted_endpoint_is_rejected_before_owner_confirmation(self):
        for endpoint in ("https://attacker.example", "http://ilinkai.weixin.qq.com", 42):
            with self.subTest(endpoint=endpoint), self.assertRaises(bridge.SafeError):
                self.run_flow([qr(), confirmed(baseurl=endpoint)])
            self.confirm.assert_not_called()

    def test_confirmed_missing_baseurl_uses_trusted_default(self):
        response = confirmed()
        del response["baseurl"]
        self.assertEqual(self.run_flow([qr(), response])["baseurl"], "https://ilinkai.weixin.qq.com")

    def test_transport_failure_propagates_without_owner_confirmation(self):
        with self.assertRaisesRegex(bridge.SafeError, "synthetic failure"):
            self.run_flow([qr(), bridge.SafeError("synthetic failure")])
        self.confirm.assert_not_called()


class CredentialFileTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "credentials.json"

    def environment(self):
        return {"SLACK_USER_TOKEN": "xoxp-synthetic-token", "SLACK_TEAM_ID": "TTEST",
                "SLACK_OWNER_ID": "UOWNER", "SLACK_DOT_DM_ID": "DDOT",
                "SLACK_DOT_USER_ID": "UDOT", "SLACK_DOT_BOT_ID": "BDOT",
                "WECHAT_CREDENTIALS_FILE": str(self.path)}

    def test_save_creates_private_round_trip_json_even_with_permissive_umask(self):
        previous = os.umask(0)
        try:
            enroll.save_credentials(self.path, credentials())
        finally:
            os.umask(previous)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(self.path.read_text()), credentials())

    def test_existing_file_is_never_overwritten(self):
        self.path.write_text("original synthetic content")
        with self.assertRaises(FileExistsError):
            enroll.save_credentials(self.path, credentials())
        self.assertEqual(self.path.read_text(), "original synthetic content")

    def test_existing_symlink_is_never_followed(self):
        target = Path(self.directory.name) / "target.json"
        target.write_text("original synthetic content")
        self.path.symlink_to(target)
        with self.assertRaises(FileExistsError):
            enroll.save_credentials(self.path, credentials())
        self.assertEqual(target.read_text(), "original synthetic content")

    def test_dangling_symlink_is_never_followed(self):
        target = Path(self.directory.name) / "absent.json"
        self.path.symlink_to(target)
        with self.assertRaises(FileExistsError):
            enroll.save_credentials(self.path, credentials())
        self.assertFalse(target.exists())

    def test_config_loads_saved_credentials_without_mutating_supplied_environment(self):
        enroll.save_credentials(self.path, credentials())
        env = self.environment()
        config = bridge.Config(env)
        self.assertEqual(config.wechat_token, "synthetic-wechat-token")
        self.assertEqual(config.wechat_account, "synthetic-account")
        self.assertEqual(config.wechat_owner, "synthetic-owner")
        self.assertEqual(config.wechat_url, "https://ilinkai.weixin.qq.com")
        self.assertNotIn("WECHAT_BOT_TOKEN", env)

    def test_config_rejects_absent_file_with_sanitized_error(self):
        with self.assertRaisesRegex(bridge.SafeError, "^Invalid private WeChat credential file$"):
            bridge.Config(self.environment())

    def test_config_rejects_invalid_json_wrong_shape_and_oversize_file(self):
        for value in ("not json", "[]", "null", "\"synthetic-secret\"", " " * 131073):
            self.path.write_text(value)
            with self.subTest(length=len(value)), self.assertRaisesRegex(
                    bridge.SafeError, "^Invalid private WeChat credential file$"):
                bridge.Config(self.environment())

    def test_config_rejects_missing_or_non_string_credential_fields(self):
        for field in credentials():
            for value in (None, 123, [], {}):
                record = credentials()
                record[field] = value
                self.path.write_text(json.dumps(record))
                with self.subTest(field=field, value_type=type(value)), self.assertRaises(bridge.SafeError):
                    bridge.Config(self.environment())
            record = credentials()
            del record[field]
            self.path.write_text(json.dumps(record))
            with self.subTest(missing=field), self.assertRaises(bridge.SafeError):
                bridge.Config(self.environment())

    def test_config_rejects_untrusted_endpoint_from_credential_file(self):
        record = credentials()
        record["baseurl"] = "https://attacker.example"
        self.path.write_text(json.dumps(record))
        with self.assertRaisesRegex(bridge.SafeError, "Untrusted WeChat API endpoint"):
            bridge.Config(self.environment())

    def token_environment(self):
        enroll.save_credentials(self.path, credentials())
        env = self.environment()
        del env["SLACK_USER_TOKEN"]
        env["SLACK_USER_TOKEN_FILE"] = str(Path(self.directory.name) / "slack-token")
        return env

    def test_config_loads_slack_token_file_without_mutating_environment(self):
        env = self.token_environment()
        Path(env["SLACK_USER_TOKEN_FILE"]).write_text("  xoxp-synthetic-from-file\n")
        self.assertEqual(bridge.Config(env).slack_token, "xoxp-synthetic-from-file")
        self.assertNotIn("SLACK_USER_TOKEN", env)

    def test_config_direct_slack_token_takes_precedence_over_file(self):
        env = self.token_environment()
        env["SLACK_USER_TOKEN"] = "xoxp-synthetic-direct"
        # The unused file need not exist and must not be opened.
        self.assertEqual(bridge.Config(env).slack_token, "xoxp-synthetic-direct")

    def test_config_rejects_missing_slack_token_file_with_sanitized_error(self):
        env = self.token_environment()
        with self.assertRaisesRegex(bridge.SafeError, "^Invalid private Slack token file$"):
            bridge.Config(env)

    def test_config_rejects_empty_and_oversized_slack_token_files(self):
        env = self.token_environment()
        for token in ("", " \n\t", "xoxp-" + "x" * 65536):
            Path(env["SLACK_USER_TOKEN_FILE"]).write_text(token)
            with self.subTest(length=len(token)), self.assertRaisesRegex(
                    bridge.SafeError, "^Invalid private Slack token file$"):
                bridge.Config(env)

    def test_config_rejects_bot_token_from_file(self):
        env = self.token_environment()
        Path(env["SLACK_USER_TOKEN_FILE"]).write_text("xoxb-synthetic-bot-token")
        with self.assertRaisesRegex(bridge.SafeError, "must be a user OAuth token"):
            bridge.Config(env)


if __name__ == "__main__":
    unittest.main()
