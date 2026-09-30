# Cloud WeChat ↔ Slack ↔ existing dot relay (experimental)

This **additional backend** runs on an always-on Linux host, independently of your PC.
It forwards the configured WeChat owner's **text** into their **existing one-to-one dot
Slack DM**, then relays only that dot's replies in the newly created Slack thread.
Direct Slack chatting still works. It never starts Codex or creates a replacement dot.
The original Swift CLI/menu-bar/Codex behavior is retained; a small explicit weak-capture
compatibility fix lets its asynchronous callbacks compile with the CI Swift toolchain.

## What is and is not verified

- Mock tests exercise filtering, persistence, correlation, pagination, rate limiting and
  ambiguous-send recovery. See the PR/Actions for actual test results.
- A separate connector-level experiment established that owner-authored messages in the
  existing dot DM can reach the same dot and its reply can be read from that thread.
- **This standalone user-OAuth runtime has not been verified against a live Slack account,
  real WeChat session, or deployed server.** The connector experiment is not proof that
  a separately installed Slack app triggers the same delivery. Test that explicitly.
- No hosting, OAuth grants, or live deployment are automatically provisioned. QR
  enrollment is a separate explicit user-driven step. A terminal process in a temporary
  assistant workspace is not durable hosting.
- WeChat iLink uses the same experimental HTTP contract as the Swift implementation;
  this is not a generally guaranteed public WeChat SDK.

## Setup (secrets stay on the chosen server)

Requirements: Python 3.10+ on Linux, or Docker Compose; outbound HTTPS; a persistent,
private writable volume; one replica only. No public ports, event webhooks, Mac, Codex
CLI, or incoming Slack bot needed.

1. Create your own Slack app using [slack-app-manifest.json](slack-app-manifest.json),
   then obtain its **user OAuth token**, with `chat:write`, `im:read`,
   `im:history`, and `users:read` user scopes, through Slack's official OAuth flow.
   An `xoxb-` bot token is deliberately rejected: it cannot impersonate the owner.
   App installation/OAuth permissions are a separate explicit user/admin action.
   These scopes may permit reading other DMs and sending as you at the Slack platform
   level; **only this code** restricts use to the configured dot DM. Slack OAuth does
   not constrain this grant to a single DM. Review that scope before consenting.
2. Enroll WeChat through the explicit cloud CLI below. It ports the original Swift
   iLink QR/status protocol, including trusted redirects, expiry, verification codes,
   and an explicit confirmation of the returned owner. QR creation follows Tencent
   documentation with POST; an explicit HTTP 405 alone permits a legacy GET fallback.
   Other HTTP/network failures stop without automatically creating another session.
   It refuses a missing owner
   instead of binding whoever sends the first message. Enrollment is not automatic
   and must only be run after the user's explicit sign-in/credential-storage approval.
   Never run old and new bridges simultaneously against the same bot/session.
   A secure secret-file handoff can supply `SLACK_USER_TOKEN_FILE` instead of the
   inline `SLACK_USER_TOKEN` value. Leave `SLACK_USER_TOKEN` unset in that case.
3. Copy `.env.example` to `cloud/.env`, replace every placeholder securely, and `chmod
   600 cloud/.env`. IDs must identify the owner, workspace, existing dot DM, dot user,
   and dot bot exactly. No IDs/tokens are hardcoded. Startup verifies Slack `auth.test`,
   `conversations.info`, and `users.info`; an owner/workspace/DM/bot mismatch stops it.
4. On your explicitly chosen always-on host, from the repository root:

   ```sh
   docker compose -f cloud/compose.yaml build
   # Interactive one-time enrollment, only after approval; scan QR and confirm on phone:
   docker compose -f cloud/compose.yaml run --rm --entrypoint python bridge /app/enroll.py --output /data/wechat-credentials.json
   docker compose -f cloud/compose.yaml run --rm bridge check
   docker compose -f cloud/compose.yaml up -d
   docker compose -f cloud/compose.yaml logs --tail=50
   ```

   `check` verifies Slack identity only and sends no message. It does not prove WeChat
   credentials, Slack relay delivery, or the same-dot external trigger.
   Compose uses a non-root user, private durable volume, no host ports and a read-only
   root filesystem. Keep the named volume when restarting/rebuilding. Do not scale it.
   For plain Python, set equivalent environment variables securely and run
   `python3 cloud/bridge.py --backend slack run` (default state: `./cloud-state`).
   Plain-Python enrollment requires optional `python3 -m pip install qrcode==8.2`,
   then `python3 cloud/enroll.py --output /private/directory/wechat-credentials.json`.
   The directory must exist. Set `WECHAT_CREDENTIALS_FILE` to that file. Never copy
   it into chat. The file is created exclusively with mode 0600 and never overwritten.
   For renewed sessions use a new file, verify the owner, then update the path.
   Already-bound QR/error statuses stop rather than revoking an existing session.
   Existing approved secret-manager values may alternatively supply `WECHAT_BOT_TOKEN`,
   `WECHAT_OWNER_ID`, `WECHAT_ACCOUNT_ID`, and `WECHAT_BASE_URL` directly.

5. Send one harmless unique text in WeChat. Verify it appears **as you** in the exact
   configured Slack DM, the existing dot answers in its thread, and the answer returns
   to WeChat. Then send another message directly in Slack and verify it stays usable.
   If the first experiment does not reach dot, stop here: do not substitute another
   bot or Codex backend and call it the same dot.

Use the cloud machine the user actually authorized. Choosing a paid host, granting
OAuth, transferring secrets, or deploying elsewhere requires the relevant approval.

## Delivery semantics and limits

- Each WeChat message creates one Slack root message in the existing DM. Only replies
  matching **both** configured dot user and bot IDs and the exact persisted `thread_ts`
  are eligible. Owner echoes, other bots, unrelated/proactive Slack messages, direct
  Slack conversations, other WeChat contacts/groups, images, voice and files are ignored.
- New reply messages and changed text snapshots are delivered as `[Slack 回复]` or
  `[Slack 消息更新]`. This is polling, **not token streaming**. A progress message is not
  mistaken for a final answer. Attachments and blocks-only messages are not mirrored.
- There is no private dot completion API. Silence is never interpreted as completion.
  Each root is observed for `BRIDGE_WINDOW_SECONDS` (default 24h; 5m–7d). At expiry it
  is **paused**, retained, and a WeChat notice says to check Slack or resume observation.
  A long-running task may keep running in dot after relay observation pauses.
- One `conversations.replies` request every 65 seconds globally, including pagination,
  with at most 15 messages/page. Active roots are round-robin. With 32 roots, each may
  take about 35 minutes per page. Busy old threads increase latency. Slack `Retry-After`
  is honored; limits are deliberately conservative for non-Marketplace app tiers.
- An atomic SQLite transaction persists accepted messages and cursor together. At most
  32 queued/watching jobs are admitted; on overflow the old cursor is kept for replay.
  Slack posts use stable client IDs, but **no exactly-once API guarantee is assumed**.
- Before every outbound mutation, the intent is durable. If the response is ambiguous
  or the process crashes in flight, the item becomes `uncertain`; it is never silently
  reposted. Explicit HTTP 429 is retried after the rate-limit delay. An API rejection is
  treated conservatively as uncertain too, rather than possibly executing twice.
- WeChat chunks are at most 3500 Unicode code points. A Slack text snapshot is limited
  to 200000 code points. Context/session expiry may prevent old replies reaching WeChat.
  Inspect Slack and status for uncertain deliveries; do not assume a successful relay.
- State contains private message text and WeChat context tokens, with restrictive file
  permissions and an exclusive single-process lock. Protect/encrypt/back up the volume
  using your host's secret/storage controls. Slack tokens use environment or `SLACK_USER_TOKEN_FILE`; WeChat tokens use the private credential file or environment; logs do not
  contain message contents, API bodies or credentials. Do not publicly expose status.
- State retains dedupe IDs and correlations across restarts. A 10000-job retention cap
  stops new ingestion rather than dropping dedupe history. There is no automatic purge;
  archive/reset only after accounting for all pending/paused/uncertain jobs. Never delete
  a live state volume to “fix” a retry, as that can replay tasks.

If enrollment reports HTTP 200 with `text/html`, the endpoint returned a web page
instead of the QR JSON contract. No QR/session should be inferred from that result.
The CLI reports the stage and safe metadata without printing the response body;
stop and investigate service/network availability rather than repeatedly retrying
or routing around an access restriction.

## Recovery and inspection

Stop the running container first; maintenance uses the same exclusive state lock:

```sh
docker compose -f cloud/compose.yaml stop bridge
docker compose -f cloud/compose.yaml run --rm bridge status
# Extend a paused root's observation window; no Slack task is reposted:
docker compose -f cloud/compose.yaml run --rm bridge resume --job WECHAT_MESSAGE_ID
# Only after manually finding an already-posted root for an uncertain Slack send:
docker compose -f cloud/compose.yaml run --rm bridge link --job WECHAT_MESSAGE_ID --thread 1234567890.123456
docker compose -f cloud/compose.yaml up -d
```

`link` checks that the existing root is authored by the owner and exactly matches the
saved original text. It consumes the same replies API budget, so may ask you to wait
65 seconds. It does not post again. If Slack transformed the original text, it refuses;
inspect manually. If no root was created, deliberately send the task again from WeChat
only after verifying that fact. Uncertain WeChat deliveries remain visible in `status`;
there is intentionally no blind resend command. Read those results in Slack.

## Tests and upstream references

```sh
python3 -m unittest discover -s cloud/tests -v
python3 -m py_compile cloud/bridge.py cloud/enroll.py
# On macOS with Swift installed (legacy regression):
swift test
```

- [Slack user vs bot tokens](https://slack.dev/two-keys-to-one-platform-understanding-bot-and-user-tokens/)
- [chat.postMessage](https://docs.slack.dev/reference/methods/chat.postMessage/)
- [conversations.replies and scopes](https://docs.slack.dev/reference/methods/conversations.replies/)
- [Web API rate limits](https://docs.slack.dev/apis/web-api/rate-limits/)
- [Cursor pagination](https://docs.slack.dev/apis/web-api/pagination/)

- [Tencent upstream iLink protocol](https://github.com/Tencent/openclaw-weixin/blob/main/docs/protocol.md)
