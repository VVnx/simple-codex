"""Offline regression tests for the owner-only cloud Slack relay.

All credentials are synthetic and every transport is mocked. Run from the repo:
    python3 -m unittest discover -s cloud/tests -v
"""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock
import urllib.error


SPEC = importlib.util.spec_from_file_location(
    "cloud_bridge_under_test", Path(__file__).resolve().parents[1] / "bridge.py")
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


def environment(state_dir="unused"):
    return {
        "SLACK_USER_TOKEN": "xoxp-synthetic-test-token",
        "SLACK_TEAM_ID": "TTEST", "SLACK_OWNER_ID": "UOWNER",
        "SLACK_DOT_DM_ID": "DDOT", "SLACK_DOT_USER_ID": "UDOT",
        "SLACK_DOT_BOT_ID": "BDOT", "WECHAT_BOT_TOKEN": "synthetic-test-token",
        "WECHAT_OWNER_ID": "wechat-owner", "WECHAT_ACCOUNT_ID": "wechat-account",
        "BRIDGE_STATE_DIR": str(state_dir), "BRIDGE_WINDOW_SECONDS": "300",
    }


def incoming(message_id=1, text="Hello dot", **changes):
    result = {
        "message_id": message_id, "message_type": 1, "message_state": 2,
        "from_user_id": "wechat-owner", "to_user_id": "wechat-account",
        "context_token": "synthetic-context", "item_list": [
            {"type": 1, "text_item": {"text": text}}],
    }
    result.update(changes)
    return result


def reply(text="Working on it", ts="1001.001", root="1000.001", **changes):
    result = {"ts": ts, "thread_ts": root, "user": "UDOT", "bot_id": "BDOT", "text": text}
    result.update(changes)
    return result


def page(*messages, cursor="", has_more=False):
    return {"messages": list(messages), "response_metadata": {"next_cursor": cursor},
            "has_more": has_more}


class ConfigurationTests(unittest.TestCase):
    def test_valid_configuration_and_window_boundaries(self):
        for seconds in (300, 86400, 604800):
            env = environment()
            env["BRIDGE_WINDOW_SECONDS"] = str(seconds)
            self.assertEqual(bridge.Config(env).window, seconds)

    def test_missing_required_values_fail_closed(self):
        for key in [k for k in environment() if not k.startswith("BRIDGE_")]:
            with self.subTest(key=key):
                env = environment()
                env[key] = " "
                with self.assertRaises(bridge.SafeError):
                    bridge.Config(env)

    def test_rejects_bot_tokens_and_bad_slack_ids(self):
        for key, value in (("SLACK_USER_TOKEN", "xoxb-bot"), ("SLACK_TEAM_ID", "U123"),
                           ("SLACK_OWNER_ID", "UOWNER\nINJECT"), ("SLACK_DOT_DM_ID", "C123"),
                           ("SLACK_DOT_USER_ID", "W123"), ("SLACK_DOT_BOT_ID", "U123"),
                           ("SLACK_DOT_USER_ID", "UOWNER")):
            with self.subTest(key=key, value=value):
                env = environment()
                env[key] = value
                with self.assertRaises(bridge.SafeError):
                    bridge.Config(env)

    def test_rejects_invalid_windows(self):
        for value in ("299", "604801", "bad", "1.5"):
            with self.subTest(value=value):
                env = environment()
                env["BRIDGE_WINDOW_SECONDS"] = value
                with self.assertRaises(bridge.SafeError):
                    bridge.Config(env)

    def test_endpoint_allowlist(self):
        for url in ("https://ilinkai.weixin.qq.com", "https://ilinkai.weixin.qq.com/",
                    "https://api.weixin.qq.com:443", "https://api.wechat.com"):
            with self.subTest(url=url):
                self.assertEqual(bridge.trusted_wechat(url), url.rstrip("/"))
        for url in ("http://ilinkai.weixin.qq.com", "https://evil.example",
                    "https://ilinkai.weixin.qq.com.evil.example", "https://evilwechat.com",
                    "https://user:pass@ilinkai.weixin.qq.com", "https://ilinkai.weixin.qq.com/api",
                    "https://ilinkai.weixin.qq.com?secret=yes", "https://ilinkai.weixin.qq.com#fragment",
                    "https://ilinkai.weixin.qq.com:444", "https://ilinkai.weixin.qq.com:bad"):
            with self.subTest(url=url):
                with self.assertRaises(bridge.SafeError):
                    bridge.trusted_wechat(url)


class InputFilterTests(unittest.TestCase):
    def setUp(self):
        self.config = bridge.Config(environment())

    def test_accepts_only_completed_owner_text_and_combines_items(self):
        message = incoming(item_list=[{"type": 1, "text_item": {"text": "  first"}},
                                      {"type": 1, "text_item": {"text": "second  "}}])
        self.assertEqual(bridge.accept(message, self.config), ("1", "synthetic-context", "first\nsecond"))
        for destination in (None, "", "wechat-account"):
            self.assertIsNotNone(bridge.accept(incoming(to_user_id=destination), self.config))

    def test_rejects_non_owner_groups_echoes_wrong_account_and_partial_messages(self):
        changes = [{"from_user_id": "other-owner"}, {"from_user_id": "wechat-account"},
                   {"to_user_id": "other-account"}, {"group_id": "group"},
                   {"message_type": 2}, {"message_state": 1}, {"message_id": "1"},
                   {"message_id": None}, {"context_token": ""}, {"context_token": None},
                   {"context_token": "x" * 65537}, {"item_list": []}, {"item_list": "text"},
                   {"item_list": [{"type": 2}]}, {"item_list": [None]},
                   {"item_list": [{"type": 1, "text_item": {"text": 1}}]}]
        for change in changes:
            with self.subTest(change=str(change)[:100]):
                self.assertIsNone(bridge.accept(incoming(**change), self.config))
        for non_message in (None, [], "string", 1):
            self.assertIsNone(bridge.accept(non_message, self.config))

    def test_text_length_and_whitespace_boundaries(self):
        self.assertIsNotNone(bridge.accept(incoming(text="x" * 35000), self.config))
        for text in ("", " \n\t ", "x" * 35001):
            self.assertIsNone(bridge.accept(incoming(text=text), self.config))

    def test_boolean_is_not_a_valid_integer_message_id(self):
        for message_id in (True, False):
            with self.subTest(message_id=message_id):
                self.assertIsNone(bridge.accept(incoming(message_id=message_id), self.config))

    def test_malformed_text_items_are_rejected_without_crashing(self):
        for malformed in (None, [], "text", 42):
            with self.subTest(malformed=malformed):
                self.assertIsNone(bridge.accept(incoming(item_list=[{"type": 1, "text_item": malformed}]),
                                                self.config))


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.http = bridge.HTTP()
        self.http.opener = mock.MagicMock()

    def respond(self, raw):
        response = mock.MagicMock()
        response.read.return_value = raw
        self.http.opener.open.return_value.__enter__.return_value = response
        return response

    def test_request_is_json_and_bounded(self):
        response = self.respond(b'{"ok": true}')
        self.assertEqual(self.http.request("https://example.test", {"X-Test": "value"}, {"a": 1}, 7),
                         {"ok": True})
        request = self.http.opener.open.call_args.args[0]
        self.assertEqual(json.loads(request.data), {"a": 1})
        self.assertEqual(self.http.opener.open.call_args.kwargs["timeout"], 7)
        response.read.assert_called_once_with(1_048_577)

    def test_invalid_and_oversized_responses_fail_safely(self):
        for raw in (b"not json", b"[]", b"null", b'"text"', b"x" * 1_048_577):
            with self.subTest(raw=raw[:15]):
                self.respond(raw)
                with self.assertRaises(bridge.SafeError):
                    self.http.request("https://example.test", {})

    def test_http_errors_hide_server_bodies_and_credentials(self):
        self.http.opener.open.side_effect = urllib.error.HTTPError(
            "https://example.test/?secret=hidden", 500, "sensitive body", {}, io.BytesIO(b"secret"))
        with self.assertRaisesRegex(bridge.SafeError, "^HTTP 500$"):
            self.http.request("https://example.test", {})

    def test_network_failures_are_sanitized(self):
        for error in (TimeoutError("secret"), OSError("secret"), urllib.error.URLError("secret")):
            with self.subTest(error=type(error).__name__):
                self.http.opener.open.side_effect = error
                with self.assertRaisesRegex(bridge.SafeError, "^API transport or response failure$"):
                    self.http.request("https://example.test", {})

    def test_retry_after_has_safe_floor_honors_large_delays_and_invalid_fallback(self):
        for header, expected in (("1", 65), ("120", 120), ("999999", 999999),
                                 ("-1", 65), ("invalid", 65), (None, 65)):
            with self.subTest(header=header):
                headers = {} if header is None else {"Retry-After": header}
                self.http.opener.open.side_effect = urllib.error.HTTPError(
                    "https://example.test", 429, "rate limited", headers, None)
                with self.assertRaises(bridge.RateLimited) as caught:
                    self.http.request("https://example.test", {})
                self.assertEqual(caught.exception.seconds, expected)

    def test_redirects_are_not_followed(self):
        self.assertIsNone(bridge.NoRedirect().redirect_request(None, None, 302, "Found", {},
                                                             "https://evil.example"))


class ApiContractTests(unittest.TestCase):
    def setUp(self):
        self.config = bridge.Config(environment())
        self.http = mock.Mock()
        self.slack = bridge.Slack(self.config, self.http)
        self.valid_auth = {"ok": True, "user_id": "UOWNER", "team_id": "TTEST"}
        self.valid_channel = {"ok": True, "channel": {"is_im": True, "user": "UDOT"}}
        self.valid_user = {"ok": True, "user": {"is_bot": True, "profile": {"bot_id": "BDOT"}}}

    def test_validate_checks_owner_team_existing_dm_and_dot_bot(self):
        self.http.request.side_effect = [self.valid_auth, self.valid_channel, self.valid_user]
        self.slack.validate()
        self.assertEqual([call.args[0].rsplit("/", 1)[-1] for call in self.http.request.call_args_list],
                         ["auth.test", "conversations.info", "users.info"])

    def test_identity_mismatch_fails_before_any_post(self):
        changes = [(0, {"user_id": "UOTHER"}), (0, {"team_id": "TOTHER"}),
                   (0, {"bot_id": "BTOKEN"}), (1, {"channel": {"is_im": False, "user": "UDOT"}}),
                   (1, {"channel": {"is_im": True, "user": "UOTHER"}}),
                   (2, {"user": {"is_bot": False, "profile": {"bot_id": "BDOT"}}}),
                   (2, {"user": {"is_bot": True, "profile": {"bot_id": "BOTHER"}}})]
        for index, change in changes:
            with self.subTest(index=index, change=change):
                results = copy.deepcopy([self.valid_auth, self.valid_channel, self.valid_user])
                results[index].update(change)
                self.http.reset_mock()
                self.http.request.side_effect = results
                with self.assertRaises(bridge.SafeError):
                    self.slack.validate()
                self.assertFalse(any("chat.postMessage" in c.args[0]
                                     for c in self.http.request.call_args_list))

    def test_invalid_cursor_has_a_specific_recoverable_error(self):
        self.http.request.return_value = {"ok": False, "error": "invalid_cursor"}
        with self.assertRaises(bridge.InvalidCursor):
            self.slack.replies("1000.001", "expired")

    def test_slack_api_rejection_does_not_log_remote_error(self):
        self.http.request.return_value = {"ok": False, "error": "private token contents"}
        with self.assertRaisesRegex(bridge.SafeError, "^Slack API rejected auth.test$"):
            self.slack.call("auth.test")

    def test_posts_as_owner_to_existing_dm_with_stable_id_and_no_unfurls(self):
        self.http.request.return_value = {"ok": True, "channel": "DDOT", "ts": "1000.001"}
        self.assertEqual(self.slack.post("hello", "stable-id"), "1000.001")
        url, headers, body = self.http.request.call_args.args
        self.assertEqual(url, "https://slack.com/api/chat.postMessage")
        self.assertEqual(headers["Authorization"], "Bearer xoxp-synthetic-test-token")
        self.assertEqual(body, {"channel": "DDOT", "text": "hello", "client_msg_id": "stable-id",
                                "unfurl_links": False, "unfurl_media": False, "parse": "none", "mrkdwn": False})

    def test_post_response_requires_exact_channel_and_valid_timestamp(self):
        for result in ({"ok": True, "channel": "DOTHER", "ts": "1000.001"},
                       {"ok": True, "channel": "DDOT", "ts": "bad"},
                       {"ok": True, "channel": "DDOT", "ts": 1000.1}):
            self.http.request.return_value = result
            with self.assertRaises(bridge.SafeError):
                self.slack.post("hello", "stable-id")

    def test_replies_uses_15_item_pages_and_exact_thread_cursor(self):
        self.http.request.return_value = {"ok": True}
        self.slack.replies("1000.001", "next-page")
        self.assertEqual(self.http.request.call_args.args[2],
                         {"channel": "DDOT", "ts": "1000.001", "limit": 15, "cursor": "next-page"})

    def test_wechat_send_is_pinned_to_owner_and_context(self):
        self.http.request.return_value = {"ret": 0}
        wechat = bridge.WeChat(self.config, self.http)
        wechat.send("context", "answer", "client", "run")
        url, headers, body = self.http.request.call_args.args
        self.assertEqual(url, "https://ilinkai.weixin.qq.com/ilink/bot/sendmessage")
        self.assertEqual(headers["Authorization"], "Bearer synthetic-test-token")
        self.assertEqual(body["msg"], {
            "from_user_id": "", "to_user_id": "wechat-owner", "client_id": "client",
            "message_type": 2, "message_state": 2, "context_token": "context", "run_id": "run",
            "item_list": [{"type": 1, "text_item": {"text": "answer"}}]})
        self.assertEqual(self.http.request.call_args.kwargs["timeout"], 130)

    def test_wechat_update_cursor_and_error_handling(self):
        wechat = bridge.WeChat(self.config, self.http)
        self.http.request.return_value = {"ret": 0, "msgs": []}
        wechat.updates("cursor")
        self.assertEqual(self.http.request.call_args.args[2]["get_updates_buf"], "cursor")
        for failure in ({"ret": 1}, {"errcode": -1}):
            self.http.request.return_value = failure
            with self.assertRaises(bridge.SafeError):
                wechat.updates("")


class StoreBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = environment(Path(self.temp.name) / "state")
        self.config = bridge.Config(self.env)
        self.store = bridge.Store(self.config)
        self.slack = mock.Mock(spec=bridge.Slack)
        self.slack.post.return_value = "1000.001"
        self.slack.replies.return_value = page()
        self.wechat = mock.Mock(spec=bridge.WeChat)
        self.now = 1000.0
        self.relay = bridge.Bridge(self.config, self.store, self.slack, self.wechat, lambda: self.now)
        # Fail loudly if any test accidentally escapes the mocked transports.
        self.network = mock.patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("network forbidden"))
        self.network.start()

    def tearDown(self):
        self.network.stop()
        if self.store is not None:
            self.store.close()
        self.temp.cleanup()

    def rows(self, table):
        return [dict(row) for row in self.store.db.execute("SELECT * FROM " + table + " ORDER BY rowid")]

    def ingest(self, *messages, cursor="cursor-1"):
        self.relay.ingest({"msgs": list(messages or (incoming(),)), "get_updates_buf": cursor})

    def watching(self, message_id=1):
        self.ingest(incoming(message_id))
        self.relay.post_one()
        return self.rows("jobs")[-1]

    def restart(self):
        self.store.close()
        self.store = bridge.Store(self.config)
        self.relay = bridge.Bridge(self.config, self.store, self.slack, self.wechat, lambda: self.now)

    def test_ingest_filters_invalid_senders_and_commits_cursor(self):
        self.ingest(incoming(), incoming(2, from_user_id="stranger"), incoming(3, message_type=2))
        self.assertEqual([r["id"] for r in self.rows("jobs")], ["1"])
        self.assertEqual(self.store.get("cursor"), "cursor-1")

    def test_duplicate_input_preserves_original_context_text_and_client(self):
        self.ingest(incoming())
        original = self.rows("jobs")[0]
        self.ingest(incoming(text="changed", context_token="changed"), cursor="cursor-2")
        self.assertEqual(self.rows("jobs"), [original])
        self.assertEqual(self.store.get("cursor"), "cursor-2")

    def test_invalid_envelope_does_not_advance_cursor_or_queue(self):
        for bad in ({"msgs": None}, {"msgs": [], "get_updates_buf": None},
                    {"msgs": [], "get_updates_buf": "x" * 65537}):
            with self.subTest(bad=str(bad)[:80]):
                with self.assertRaises(bridge.SafeError):
                    self.relay.ingest(bad)
                self.assertEqual(self.rows("jobs"), [])
                self.assertEqual(self.store.get("cursor"), "")

    def test_database_failure_rolls_back_whole_ingestion_and_cursor(self):
        with self.store.db:
            self.store.put("cursor", "before")
            self.store.db.execute("""CREATE TRIGGER reject_second BEFORE INSERT ON jobs
                WHEN NEW.id='2' BEGIN SELECT RAISE(ABORT, 'injected failure'); END""")
        with self.assertRaises(sqlite3.IntegrityError):
            self.ingest(incoming(1), incoming(2), cursor="after")
        self.assertEqual(self.rows("jobs"), [])
        self.assertEqual(self.store.get("cursor"), "before")

    def test_queue_capacity_commits_prefix_retains_cursor_then_recovers_without_duplicates(self):
        with self.store.db:
            self.store.put("cursor", "before")
        messages = [incoming(i) for i in range(1, 35)]
        self.ingest(*messages, cursor="after")
        self.assertEqual(len(self.rows("jobs")), 32)
        self.assertEqual(self.store.get("cursor"), "before")
        first_client = self.rows("jobs")[0]["client"]
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET phase='paused' WHERE id IN ('1','2')")
        self.ingest(*messages, cursor="after")
        self.assertEqual(len(self.rows("jobs")), 34)
        self.assertEqual(self.store.get("cursor"), "after")
        self.assertEqual(self.rows("jobs")[0]["client"], first_client)

    def test_exact_capacity_batch_can_advance_cursor(self):
        self.ingest(*[incoming(i) for i in range(32)], cursor="after")
        self.assertEqual(len(self.rows("jobs")), 32)
        self.assertEqual(self.store.get("cursor"), "after")

    def test_post_persists_watch_and_scrubs_original_text(self):
        self.watching()
        job = self.rows("jobs")[0]
        self.slack.post.assert_called_once_with("Hello dot", job["client"])
        self.assertEqual((job["phase"], job["ts"], job["deadline"], job["text"]),
                         ("watching", "1000.001", 1300.0, ""))
        self.relay.post_one()
        self.slack.post.assert_called_once()

    def test_slack_post_rate_limit_retries_only_after_persisted_budget(self):
        self.ingest(incoming(1), incoming(2))
        self.slack.post.side_effect = [bridge.RateLimited(120), "1000.001"]
        original_client = self.rows("jobs")[0]["client"]
        self.relay.post_one()
        self.assertEqual(self.rows("jobs")[0]["phase"], "queued")
        self.assertEqual(float(self.store.get("post_after")), 1120)
        self.restart()
        self.now = 1119
        self.relay.post_one()
        self.assertEqual(self.slack.post.call_count, 1)
        self.now = 1120
        self.relay.post_one()
        self.assertEqual(self.slack.post.call_count, 2)
        self.assertEqual(self.slack.post.call_args.args[1], original_client)

    def test_two_posts_respect_global_two_second_spacing(self):
        self.ingest(incoming(1), incoming(2))
        self.relay.post_one()
        self.now += 1
        self.relay.post_one()
        self.assertEqual(self.slack.post.call_count, 1)
        self.now += 1
        self.relay.post_one()
        self.assertEqual(self.slack.post.call_count, 2)

    def test_ambiguous_slack_mutation_is_never_retried_even_after_restart(self):
        self.ingest()
        self.slack.post.side_effect = bridge.SafeError("transport failure")
        self.relay.post_one()
        self.assertEqual(self.rows("jobs")[0]["phase"], "uncertain")
        self.assertEqual(len(self.rows("outbox")), 1)
        self.assertIn("不确定", self.rows("outbox")[0]["text"])
        self.restart()
        self.now += 1000
        self.relay.post_one()
        self.slack.post.assert_called_once()

    def test_process_crash_during_post_is_marked_uncertain_on_restart(self):
        self.ingest()
        self.slack.post.side_effect = KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            self.relay.post_one()
        self.assertEqual(self.rows("jobs")[0]["phase"], "posting")
        self.restart()
        self.assertEqual(self.rows("jobs")[0]["phase"], "uncertain")
        self.now += 1000
        self.relay.post_one()
        self.slack.post.assert_called_once()

    def test_reply_filter_rejects_root_owner_echoes_wrong_threads_bots_and_subtypes(self):
        self.watching()
        bad = [reply(ts="1000.001"), reply(user="UOWNER"), reply(user="UOTHER"),
               reply(bot_id="BOTHER"), reply(bot_id=None), reply(thread_ts="999.001"),
               reply(thread_ts=None), reply(subtype="message_changed"), reply(text=" \n "),
               reply(text=None), reply(ts="invalid"), "not a message"]
        self.slack.replies.return_value = page(*bad, reply(text="valid"),
                                               reply(text="also valid", ts="1002.001", subtype="bot_message"))
        self.relay.poll_one()
        texts = [row["text"] for row in self.rows("outbox")]
        self.assertEqual(texts, ["[Slack 回复]\nvalid", "[Slack 回复]\nalso valid"])
        self.assertEqual(len(self.rows("replies")), 2)

    def test_multiple_replies_and_edits_are_forwarded_once_without_declaring_completion(self):
        self.watching()
        self.slack.replies.return_value = page(reply("Progress"), reply("Finished", ts="1002.001"))
        self.relay.poll_one()
        self.now += 65
        self.slack.replies.return_value = page(reply("Progress"), reply("Finished", ts="1002.001"),
                                               reply("Progress updated"))
        self.relay.poll_one()
        self.assertEqual([r["text"] for r in self.rows("outbox")],
                         ["[Slack 回复]\nProgress", "[Slack 回复]\nFinished", "[Slack 消息更新]\nProgress updated"])
        self.assertEqual(self.rows("jobs")[0]["phase"], "watching")
        self.restart()
        self.now += 65
        self.relay.poll_one()
        self.assertEqual(len(self.rows("outbox")), 3)

    def test_output_chunking_is_lossless_bounded_and_idempotent(self):
        self.watching()
        text = "中文🙂" * 3000
        self.slack.replies.return_value = page(reply(text))
        self.relay.poll_one()
        rows = self.rows("outbox")
        self.assertEqual("".join(r["text"] for r in rows), "[Slack 回复]\n" + text)
        self.assertTrue(all(0 < len(r["text"]) <= 3500 for r in rows))
        ids = [r["id"] for r in rows]
        self.assertEqual(len(ids), len(set(ids)))
        self.now += 65
        self.relay.poll_one()
        self.assertEqual([r["id"] for r in self.rows("outbox")], ids)

    def test_restart_resets_ephemeral_cursor_but_preserves_global_read_budget(self):
        self.watching()
        self.slack.replies.side_effect = [page(reply(), cursor="page-2", has_more=True),
                                          page(reply("second page", ts="1002.001"))]
        self.relay.poll_one()
        self.assertEqual(self.rows("jobs")[0]["cursor"], "page-2")
        self.assertEqual(float(self.store.get("poll_after")), 1065)
        self.restart()
        self.now = 1064
        self.relay.poll_one()
        self.assertEqual(self.slack.replies.call_count, 1)
        self.now = 1065
        self.relay.poll_one()
        self.assertEqual(self.slack.replies.call_args_list,
                         [mock.call("1000.001", ""), mock.call("1000.001", "")])
        self.assertEqual(self.rows("jobs")[0]["cursor"], "")
        self.assertEqual(len(self.rows("outbox")), 2)

    def test_pagination_fetches_next_page_under_same_global_budget(self):
        self.watching()
        self.slack.replies.side_effect = [page(reply(), cursor="page-2", has_more=True),
                                          page(reply("second", ts="1002.001"))]
        self.relay.poll_one()
        self.now += 64
        self.relay.poll_one()
        self.slack.replies.assert_called_once()
        self.now += 1
        self.relay.poll_one()
        self.assertEqual(self.slack.replies.call_args_list,
                         [mock.call("1000.001", ""), mock.call("1000.001", "page-2")])
        self.assertEqual(len(self.rows("outbox")), 2)

    def test_expired_page_cursor_restarts_snapshot_without_replaying_replies(self):
        self.watching()
        self.slack.replies.side_effect = [page(reply(), cursor="expired", has_more=True),
                                          bridge.InvalidCursor("expired"), page(reply())]
        self.relay.poll_one()
        self.now += 65
        self.relay.poll_one()
        self.assertEqual(self.rows("jobs")[0]["cursor"], "")
        self.assertEqual(float(self.store.get("poll_after")), 1130)
        self.now += 65
        self.relay.poll_one()
        self.assertEqual(self.slack.replies.call_args_list,
                         [mock.call("1000.001", ""), mock.call("1000.001", "expired"),
                          mock.call("1000.001", "")])
        self.assertEqual(len(self.rows("outbox")), 1)
        self.assertEqual(len(self.rows("replies")), 1)

    def test_read_retry_after_starts_when_slow_request_returns(self):
        self.watching()
        def slow_rate_limit(*_):
            self.now += 40
            raise bridge.RateLimited(120)
        self.slack.replies.side_effect = slow_rate_limit
        self.relay.poll_one()
        self.assertEqual(float(self.store.get("poll_after")), 1160)

    def test_post_retry_after_starts_when_slow_request_returns(self):
        self.ingest()
        def slow_rate_limit(*_):
            self.now += 40
            raise bridge.RateLimited(120)
        self.slack.post.side_effect = slow_rate_limit
        self.relay.post_one()
        self.assertEqual(float(self.store.get("post_after")), 1160)

    def test_send_retry_after_starts_when_slow_request_returns(self):
        self.watching()
        with self.store.db:
            self.relay.enqueue("1", "answer", "answer")
        def slow_rate_limit(*_):
            self.now += 40
            raise bridge.RateLimited(120)
        self.wechat.send.side_effect = slow_rate_limit
        self.relay.deliver_one()
        self.assertEqual(float(self.store.get("send_after")), 1160)

    def test_crash_recovery_enqueues_one_stable_uncertainty_notice(self):
        self.ingest()
        self.slack.post.side_effect = KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            self.relay.post_one()
        self.assertEqual(self.rows("outbox"), [])
        self.restart()
        rows = self.rows("outbox")
        self.assertEqual(len(rows), 1)
        self.assertIn("不确定", rows[0]["text"])
        self.restart()
        self.assertEqual(self.rows("outbox"), rows)
        self.slack.post.assert_called_once()

    def test_huge_reply_is_chunked_and_explicitly_marked_truncated(self):
        self.watching()
        self.slack.replies.return_value = page(reply("x" * 200001))
        self.relay.poll_one()
        text = "".join(r["text"] for r in self.rows("outbox"))
        self.assertEqual(text.count("x"), 200000)
        self.assertIn("已截断", text)
        self.assertTrue(all(len(r["text"]) <= 3500 for r in self.rows("outbox")))

    def test_global_read_budget_applies_across_jobs_and_round_robin(self):
        self.watching(1)
        self.now += 2
        self.slack.post.return_value = "2000.001"
        self.watching(2)
        self.relay.poll_one()
        self.relay.poll_one()
        self.assertEqual(self.slack.replies.call_count, 1)
        self.now += 65
        self.relay.poll_one()
        self.assertEqual(self.slack.replies.call_args_list,
                         [mock.call("1000.001", ""), mock.call("2000.001", "")])

    def test_retry_after_preserves_page_cursor_and_global_budget(self):
        self.watching()
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET cursor='page-2'")
        self.slack.replies.side_effect = bridge.RateLimited(120)
        self.relay.poll_one()
        self.assertEqual(self.rows("jobs")[0]["cursor"], "page-2")
        self.assertEqual(float(self.store.get("poll_after")), 1120)
        self.now = 1119
        self.relay.poll_one()
        self.slack.replies.assert_called_once()

    def test_failed_read_still_reserves_budget_without_changing_cursor(self):
        self.watching()
        self.slack.replies.side_effect = bridge.SafeError("read failure")
        with self.assertRaises(bridge.SafeError):
            self.relay.poll_one()
        self.assertEqual(float(self.store.get("poll_after")), 1065)
        self.assertEqual(self.rows("jobs")[0]["cursor"], "")
        self.relay.poll_one()
        self.slack.replies.assert_called_once()

    def test_invalid_pagination_does_not_enqueue_or_advance_cursor(self):
        self.watching()
        for response in ({"messages": None}, page(reply(), has_more=True),
                         {"messages": [reply()], "response_metadata": {"next_cursor": 42}},
                         {"messages": [reply()], "response_metadata": {"next_cursor": "x" * 4097}}):
            with self.subTest(response=str(response)[:100]):
                self.slack.replies.return_value = response
                with self.assertRaises(bridge.SafeError):
                    self.relay.poll_one()
                self.assertEqual(self.rows("outbox"), [])
                self.assertEqual(self.rows("replies"), [])
                self.assertEqual(self.rows("jobs")[0]["cursor"], "")
                self.now += 65

    def test_malformed_slack_metadata_fails_safely(self):
        self.watching()
        for metadata in (None, [], "bad"):
            with self.subTest(metadata=metadata):
                self.slack.replies.return_value = {"messages": [reply()], "response_metadata": metadata}
                with self.assertRaises(bridge.SafeError):
                    self.relay.poll_one()
                self.now += 65

    def test_reply_dedup_outbox_and_cursor_update_are_atomic(self):
        self.watching()
        self.slack.replies.return_value = page(reply(), cursor="page-2", has_more=True)
        with mock.patch.object(self.relay, "enqueue", side_effect=sqlite3.OperationalError("injected")):
            with self.assertRaises(sqlite3.OperationalError):
                self.relay.poll_one()
        self.assertEqual(self.rows("replies"), [])
        self.assertEqual(self.rows("outbox"), [])
        self.assertEqual(self.rows("jobs")[0]["cursor"], "")
        self.assertEqual(float(self.store.get("poll_after")), 1065)
        self.now += 65
        self.relay.poll_one()
        self.assertEqual(len(self.rows("replies")), 1)
        self.assertEqual(len(self.rows("outbox")), 1)
        self.assertEqual(self.rows("jobs")[0]["cursor"], "page-2")

    def test_delivery_uses_original_owner_context_and_scrubs_sent_text(self):
        job = self.watching()
        with self.store.db:
            self.relay.enqueue("1", "answer", "Answer")
        outbox_id = self.rows("outbox")[0]["id"]
        self.relay.deliver_one()
        self.wechat.send.assert_called_once_with("synthetic-context", "Answer", outbox_id, job["client"])
        self.assertEqual((self.rows("outbox")[0]["phase"], self.rows("outbox")[0]["text"]), ("sent", ""))
        self.relay.deliver_one()
        self.wechat.send.assert_called_once()

    def test_ambiguous_wechat_mutation_is_not_retried_after_restart(self):
        self.watching()
        with self.store.db:
            self.relay.enqueue("1", "answer", "Answer")
        self.wechat.send.side_effect = bridge.SafeError("ambiguous")
        with contextlib.redirect_stdout(io.StringIO()):
            self.relay.deliver_one()
        self.assertEqual(self.rows("outbox")[0]["phase"], "uncertain")
        self.restart()
        self.now += 65
        self.relay.deliver_one()
        self.wechat.send.assert_called_once()

    def test_process_crash_during_wechat_send_is_not_replayed(self):
        self.watching()
        with self.store.db:
            self.relay.enqueue("1", "answer", "Answer")
        self.wechat.send.side_effect = KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            self.relay.deliver_one()
        self.assertEqual(self.rows("outbox")[0]["phase"], "sending")
        self.restart()
        self.assertEqual(self.rows("outbox")[0]["phase"], "uncertain")
        self.now += 65
        self.relay.deliver_one()
        self.wechat.send.assert_called_once()

    def test_wechat_explicit_rate_limit_requeues_with_stable_ids(self):
        self.watching()
        with self.store.db:
            self.relay.enqueue("1", "answer", "Answer")
        self.wechat.send.side_effect = [bridge.RateLimited(90), None]
        self.relay.deliver_one()
        self.assertEqual(self.rows("outbox")[0]["phase"], "queued")
        self.restart()
        self.now += 89
        self.relay.deliver_one()
        self.wechat.send.assert_called_once()
        self.now += 1
        self.relay.deliver_one()
        self.assertEqual(self.wechat.send.call_args_list[0], self.wechat.send.call_args_list[1])
        self.assertEqual(self.rows("outbox")[0]["phase"], "sent")

    def test_delivery_fifo_and_one_second_spacing(self):
        self.watching()
        with self.store.db:
            self.relay.enqueue("1", "one", "first")
            self.relay.enqueue("1", "two", "second")
        self.relay.deliver_one()
        self.relay.deliver_one()
        self.wechat.send.assert_called_once()
        self.now += 1
        self.relay.deliver_one()
        self.assertEqual([c.args[1] for c in self.wechat.send.call_args_list], ["first", "second"])

    def test_timeout_pauses_observation_retains_thread_and_sends_single_notice(self):
        self.watching()
        self.now = 1300
        self.relay.poll_one()
        job = self.rows("jobs")[0]
        self.assertEqual((job["phase"], job["ts"]), ("paused", "1000.001"))
        self.slack.replies.assert_not_called()
        self.assertEqual(len(self.rows("outbox")), 1)
        self.assertIn("任务是否完成仍以 Slack 为准", self.rows("outbox")[0]["text"])
        self.restart()
        self.now += 100
        self.relay.poll_one()
        self.assertEqual(len(self.rows("outbox")), 1)
        self.slack.replies.assert_not_called()

    def test_expiration_runs_even_while_read_budget_is_throttled(self):
        self.watching()
        with self.store.db:
            self.store.put("poll_after", 99999)
        self.now = 1300
        self.relay.poll_one()
        self.assertEqual(self.rows("jobs")[0]["phase"], "paused")
        self.assertEqual(len(self.rows("outbox")), 1)

    def test_identity_binding_rejects_each_changed_identity(self):
        self.store.close()
        self.store = None
        for key, value in (("SLACK_TEAM_ID", "TOTHER"), ("SLACK_OWNER_ID", "UOTHER"),
                           ("SLACK_DOT_DM_ID", "DOTHER"), ("SLACK_DOT_USER_ID", "UOTHER"),
                           ("SLACK_DOT_BOT_ID", "BOTHER"), ("WECHAT_OWNER_ID", "other"),
                           ("WECHAT_ACCOUNT_ID", "other")):
            with self.subTest(key=key):
                env = dict(self.env, **{key: value})
                # Retain the rejected object's resources long enough to close them explicitly.
                rejected = bridge.Store.__new__(bridge.Store)
                try:
                    with self.assertRaises(bridge.SafeError):
                        rejected.__init__(bridge.Config(env))
                finally:
                    if hasattr(rejected, "db"):
                        rejected.db.close()
                    if hasattr(rejected, "lock"):
                        rejected.lock.close()

    def test_state_directory_is_private_and_single_writer_locked(self):
        self.assertEqual(self.config.state_dir.stat().st_mode & 0o777, 0o700)
        with self.assertRaisesRegex(bridge.SafeError, "Another bridge owns"):
            bridge.Store(self.config)

    def cli(self, *args, error=None):
        self.store.close()
        self.store = None
        output = io.StringIO()
        try:
            with mock.patch.dict(os.environ, self.env, clear=True), \
                    mock.patch.object(bridge.sys, "argv", ["bridge.py", *args]), \
                    mock.patch.object(bridge, "Slack", return_value=self.slack), \
                    mock.patch.object(bridge, "WeChat", return_value=self.wechat), \
                    mock.patch.object(bridge, "HTTP"), \
                    mock.patch.object(bridge.time, "time", return_value=self.now), \
                    mock.patch.object(bridge.os, "umask"), contextlib.redirect_stdout(output):
                if error:
                    with self.assertRaises(error):
                        bridge.main()
                else:
                    bridge.main()
        finally:
            self.store = bridge.Store(self.config)
            self.relay = bridge.Bridge(self.config, self.store, self.slack, self.wechat, lambda: self.now)
        return output.getvalue()

    def test_cli_check_validates_only_and_discloses_wechat_not_verified(self):
        output = self.cli("check")
        self.slack.validate.assert_called_once()
        self.slack.post.assert_not_called()
        self.wechat.send.assert_not_called()
        self.wechat.updates.assert_not_called()
        self.assertIn("WeChat credentials not verified", output)

    def test_cli_status_is_read_only_and_does_not_expose_text_or_context(self):
        self.ingest(incoming(text="private user text", context_token="private context"))
        output = self.cli("status")
        self.slack.validate.assert_not_called()
        self.assertIn("queued", output)
        self.assertNotIn("private", output)
        self.slack.post.assert_not_called()
        self.wechat.send.assert_not_called()

    def test_cli_resume_reopens_paused_mapping_without_repost_or_losing_dedup(self):
        self.watching()
        self.slack.replies.return_value = page(reply())
        self.relay.poll_one()
        self.now = 1300
        self.relay.poll_one()
        self.now = 1400
        before_replies = self.rows("replies")
        self.slack.post.reset_mock()
        output = self.cli("resume", "--job", "1")
        job = self.rows("jobs")[0]
        self.assertEqual((job["phase"], job["ts"], job["deadline"], job["cursor"]),
                         ("watching", "1000.001", 1700.0, ""))
        self.assertEqual(self.rows("replies"), before_replies)
        self.slack.post.assert_not_called()
        self.assertIn("no task reposted", output)
        self.relay.poll_one()
        self.assertEqual(len(self.rows("replies")), 1)

    def test_cli_resume_requires_known_paused_job(self):
        self.ingest()
        self.cli("resume", "--job", "1", error=bridge.SafeError)
        self.cli("resume", "--job", "missing", error=bridge.SafeError)
        self.slack.post.assert_not_called()
        self.assertEqual(self.rows("jobs")[0]["phase"], "queued")

    def test_cli_link_verifies_original_owner_and_text_without_reposting(self):
        self.ingest()
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET phase='uncertain'")
        self.slack.replies.return_value = page({"ts": "2000.001", "user": "UOWNER", "text": "Hello dot"})
        output = self.cli("link", "--job", "1", "--thread", "2000.001")
        job = self.rows("jobs")[0]
        self.assertEqual((job["phase"], job["ts"], job["text"]), ("watching", "2000.001", ""))
        self.assertEqual(float(self.store.get("poll_after")), 1065)
        self.slack.post.assert_not_called()
        self.assertIn("no task reposted", output)

    def test_cli_link_rejects_wrong_owner_text_thread_or_existing_budget(self):
        self.ingest()
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET phase='uncertain'")
        for root in ({"ts": "2000.001", "user": "UOTHER", "text": "Hello dot"},
                     {"ts": "2000.001", "user": "UOWNER", "text": "other text"},
                     {"ts": "9999.001", "user": "UOWNER", "text": "Hello dot"}):
            self.slack.replies.return_value = page(root)
            self.cli("link", "--job", "1", "--thread", "2000.001", error=bridge.SafeError)
            self.assertEqual(self.rows("jobs")[0]["phase"], "uncertain")
            self.now += 65
        with self.store.db:
            self.store.put("poll_after", self.now + 65)
        self.slack.replies.reset_mock()
        self.cli("link", "--job", "1", "--thread", "2000.001", error=bridge.SafeError)
        self.slack.replies.assert_not_called()
        self.slack.post.assert_not_called()

    def test_main_acknowledges_committed_cursor_not_uncommitted_remote_cursor(self):
        self.ingest(*[incoming(i) for i in range(32)], cursor="before")
        inbox, ack = mock.Mock(), mock.Mock()
        inbox.get_nowait.return_value = ({"msgs": [incoming(99)], "get_updates_buf": "after"}, ack)
        with mock.patch("queue.Queue", return_value=inbox), mock.patch("threading.Thread"), \
                mock.patch.object(bridge.Bridge, "post_one"), mock.patch.object(bridge.Bridge, "poll_one"), \
                mock.patch.object(bridge.Bridge, "deliver_one"), \
                mock.patch.object(bridge.time, "sleep", side_effect=KeyboardInterrupt):
            self.cli("run", error=KeyboardInterrupt)
        ack.put.assert_called_once_with("before")
        self.assertEqual(self.store.get("cursor"), "before")
        self.assertEqual(len(self.rows("jobs")), 32)

    def test_reader_waits_when_committed_cursor_does_not_advance(self):
        self.ingest(cursor="before")
        inbox, ack, stop = mock.Mock(), mock.Mock(), mock.Mock()
        response = {"msgs": [], "get_updates_buf": "before"}
        self.wechat.updates.return_value = response
        ack.get.return_value = "before"
        inbox.get_nowait.return_value = (response, ack)
        stop.is_set.side_effect = [False, True]
        def fake_thread(target, daemon):
            thread = mock.Mock()
            thread.start.side_effect = target
            return thread
        with mock.patch("queue.Queue", side_effect=[inbox, ack]), \
                mock.patch("threading.Event", return_value=stop), \
                mock.patch("threading.Thread", side_effect=fake_thread), \
                mock.patch.object(bridge.Bridge, "post_one"), mock.patch.object(bridge.Bridge, "poll_one"), \
                mock.patch.object(bridge.Bridge, "deliver_one"), \
                mock.patch.object(bridge.time, "sleep", side_effect=KeyboardInterrupt):
            self.cli("run", error=KeyboardInterrupt)
        self.wechat.updates.assert_called_once_with("before")
        inbox.put.assert_called_once_with((response, ack))
        stop.wait.assert_called_once_with(30)
        stop.set.assert_called_once()

    def test_main_does_not_acknowledge_failed_ingestion(self):
        inbox, ack = mock.Mock(), mock.Mock()
        inbox.get_nowait.return_value = ({"msgs": [incoming()], "get_updates_buf": "after"}, ack)
        with mock.patch("queue.Queue", return_value=inbox), mock.patch("threading.Thread"), \
                mock.patch.object(bridge.Bridge, "ingest", side_effect=sqlite3.OperationalError("injected")):
            self.cli("run", error=sqlite3.OperationalError)
        ack.put.assert_not_called()
        self.assertEqual(self.store.get("cursor"), "")


if __name__ == "__main__":
    unittest.main()
