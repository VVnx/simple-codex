#!/usr/bin/env python3
"""PC-independent, owner-only WeChat → Slack → existing dot relay.
No Codex process, private dot API, external dependencies, or inbound HTTP server.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class SafeError(Exception):
    """Only fixed/sanitized descriptions may leave the transport layer."""


class HTTPStatusError(SafeError):
    def __init__(self, status):
        self.status = status
        super().__init__(f'HTTP {status}')


class InvalidCursor(SafeError):
    pass


class RateLimited(SafeError):
    def __init__(self, seconds):
        self.seconds = max(65, int(seconds))
        super().__init__('API rate limited')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class HTTP:
    def __init__(self):
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, url, headers, body=None, timeout=45):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, headers=headers)
        try:
            with self.opener.open(req, timeout=timeout) as response:
                raw = response.read(1_048_577)
                if len(raw) > 1_048_576:
                    raise SafeError('API response exceeds limit')
                try:
                    result = json.loads(raw)
                except (ValueError, UnicodeError):
                    status = getattr(response, 'status', None)
                    status = status if isinstance(status, int) else 'unknown'
                    content_type = response.headers.get('Content-Type', '')
                    content_type = content_type.split(';', 1)[0].strip().lower() if isinstance(content_type, str) else 'unknown'
                    if content_type not in ('application/json', 'text/html', 'text/plain', 'application/octet-stream'):
                        content_type = 'other'
                    raise SafeError(f'API returned non-JSON response (HTTP {status}; content-type {content_type})') from None
                if not isinstance(result, dict):
                    raise SafeError('Invalid API response')
                return result
        except urllib.error.HTTPError as exc:
            if exc.code == 429:
                try:
                    seconds = int(exc.headers.get('Retry-After', '65'))
                except ValueError:
                    seconds = 65
                exc.close()
                raise RateLimited(seconds) from None
            status = exc.code
            exc.close()
            raise HTTPStatusError(status) from None
        except (ValueError, OSError, urllib.error.URLError):
            raise SafeError('API transport or response failure') from None


def required(env, key):
    value = env.get(key, '').strip()
    if not value:
        raise SafeError(f'Missing {key}')
    return value


def trusted_wechat(raw):
    url = urllib.parse.urlsplit(raw)
    host = url.hostname or ''
    try:
        valid = (url.scheme == 'https' and not url.username and not url.password
                 and not url.query and not url.fragment and url.path in ('', '/')
                 and url.port in (None, 443) and (host == 'ilinkai.weixin.qq.com'
                 or host.endswith('.weixin.qq.com') or host.endswith('.wechat.com')))
    except ValueError:
        valid = False
    if not valid:
        raise SafeError('Untrusted WeChat API endpoint')
    return raw.rstrip('/')


class Config:
    def __init__(self, env):
        env = dict(env)
        slack_token_file = env.get('SLACK_USER_TOKEN_FILE')
        if slack_token_file and not env.get('SLACK_USER_TOKEN'):
            try:
                with open(slack_token_file) as file:
                    token = file.read(65537).strip()
                if not 0 < len(token) <= 65536:
                    raise ValueError()
                env['SLACK_USER_TOKEN'] = token
            except (OSError, ValueError):
                raise SafeError('Invalid private Slack token file') from None
        credential_file = env.get('WECHAT_CREDENTIALS_FILE')
        if credential_file:
            try:
                with open(credential_file) as file:
                    raw = file.read(131073)
                if len(raw) > 131072:
                    raise ValueError()
                credentials = json.loads(raw)
                if not isinstance(credentials, dict):
                    raise ValueError()
                for key, field in [('WECHAT_BOT_TOKEN', 'bot_token'), ('WECHAT_ACCOUNT_ID', 'ilink_bot_id'),
                                   ('WECHAT_OWNER_ID', 'ilink_user_id'), ('WECHAT_BASE_URL', 'baseurl')]:
                    value = credentials.get(field)
                    if not isinstance(value, str):
                        raise ValueError()
                    env.setdefault(key, value)
            except (OSError, ValueError):
                raise SafeError('Invalid private WeChat credential file') from None
        self.slack_token = required(env, 'SLACK_USER_TOKEN')
        if not self.slack_token.startswith('xoxp-'):
            raise SafeError('SLACK_USER_TOKEN must be a user OAuth token (xoxp-)')
        for attr, key, prefix in [('team', 'SLACK_TEAM_ID', 'T'),
                                  ('owner', 'SLACK_OWNER_ID', 'U'),
                                  ('channel', 'SLACK_DOT_DM_ID', 'D'),
                                  ('dot', 'SLACK_DOT_USER_ID', 'U'),
                                  ('bot', 'SLACK_DOT_BOT_ID', 'B')]:
            value = required(env, key)
            if not re.fullmatch(prefix + '[A-Z0-9]+', value):
                raise SafeError(f'Invalid {key}')
            setattr(self, attr, value)
        if self.owner == self.dot:
            raise SafeError('Owner and dot must differ')
        self.wechat_token = required(env, 'WECHAT_BOT_TOKEN')
        self.wechat_owner = required(env, 'WECHAT_OWNER_ID')
        self.wechat_account = required(env, 'WECHAT_ACCOUNT_ID')
        self.wechat_url = trusted_wechat(env.get('WECHAT_BASE_URL', 'https://ilinkai.weixin.qq.com'))
        self.state_dir = Path(env.get('BRIDGE_STATE_DIR', './cloud-state'))
        try:
            self.window = int(env.get('BRIDGE_WINDOW_SECONDS', '86400'))
        except ValueError:
            raise SafeError('Invalid BRIDGE_WINDOW_SECONDS') from None
        if not 300 <= self.window <= 604800:
            raise SafeError('BRIDGE_WINDOW_SECONDS must be 300..604800')

    def binding(self):
        return json.dumps([self.team, self.owner, self.channel, self.dot, self.bot,
                           self.wechat_account, self.wechat_owner])


class Slack:
    def __init__(self, config, http):
        self.c, self.http = config, http

    def call(self, method, **body):
        url = 'https://slack.com/api/' + method
        headers = {'Authorization': 'Bearer ' + self.c.slack_token}
        if method in ('conversations.info', 'users.info', 'conversations.replies'):
            # Slack's read methods use GET query parameters, as in its official SDK.
            # Keep the credential exclusively in the Authorization header.
            params = {key: value for key, value in body.items() if value not in (None, '')}
            query = urllib.parse.urlencode(params)
            result = self.http.request(url + ('?' + query if query else ''), headers)
        else:
            headers['Content-Type'] = 'application/json; charset=utf-8'
            result = self.http.request(url, headers, body)
        if result.get('ok') is not True:
            if result.get('error') == 'invalid_cursor':
                raise InvalidCursor('Slack pagination cursor expired')
            # Never reflect server messages/tokens/user text into logs.
            raise SafeError('Slack API rejected ' + method)
        return result

    def validate(self):
        auth = self.call('auth.test')
        if (auth.get('user_id') != self.c.owner or auth.get('team_id') != self.c.team
                or auth.get('bot_id')):
            raise SafeError('Slack token owner/workspace mismatch')
        channel = self.call('conversations.info', channel=self.c.channel).get('channel', {})
        if not channel.get('is_im') or channel.get('user') != self.c.dot:
            raise SafeError('Configured channel is not the existing dot DM')
        user = self.call('users.info', user=self.c.dot).get('user', {})
        if not user.get('is_bot') or user.get('profile', {}).get('bot_id') != self.c.bot:
            raise SafeError('Configured dot bot identity mismatch')

    def post(self, text, client_id):
        result = self.call('chat.postMessage', channel=self.c.channel, text=text,
                           client_msg_id=client_id, unfurl_links=False, unfurl_media=False,
                           parse='none', mrkdwn=False)
        ts = result.get('ts')
        if result.get('channel') != self.c.channel or not valid_ts(ts):
            raise SafeError('Unverified Slack post response')
        return ts

    def replies(self, ts, cursor):
        return self.call('conversations.replies', channel=self.c.channel, ts=ts,
                         limit=15, cursor=cursor)


def valid_ts(ts):
    return isinstance(ts, str) and re.fullmatch(r'\d+\.\d+', ts) is not None


class WeChat:
    def __init__(self, config, http):
        self.c, self.http = config, http

    def call(self, method, body):
        headers = {'Authorization': 'Bearer ' + self.c.wechat_token,
                   'AuthorizationType': 'ilink_bot_token', 'Content-Type': 'application/json',
                   'iLink-App-Id': 'bot', 'iLink-App-ClientVersion': '132102',
                   'X-WECHAT-UIN': base64.b64encode(str(int.from_bytes(os.urandom(4), byteorder='big')).encode()).decode()}
        result = self.http.request(self.c.wechat_url + '/ilink/bot/' + method, headers,
                                   dict(body, base_info={'channel_version': '2.4.6',
                                                       'bot_agent': 'SimpleCodexCloud/0.1.0'}), timeout=130)
        if result.get('ret', 0) != 0 or result.get('errcode', 0) != 0:
            raise SafeError('WeChat API rejected request; check credentials/session')
        return result

    def updates(self, cursor):
        return self.call('getupdates', {'get_updates_buf': cursor})

    def send(self, context, text, client_id, run_id):
        self.call('sendmessage', {'msg': {'from_user_id': '', 'to_user_id': self.c.wechat_owner,
                  'client_id': client_id, 'message_type': 2, 'message_state': 2,
                  'item_list': [{'type': 1, 'text_item': {'text': text}}],
                  'context_token': context, 'run_id': run_id}})


def accept(message, config):
    if not isinstance(message, dict):
        return None
    if (message.get('message_type') != 1 or message.get('message_state') != 2
            or message.get('group_id') or message.get('from_user_id') != config.wechat_owner
            or message.get('to_user_id') not in (None, '', config.wechat_account)
            or type(message.get('message_id')) is not int):
        return None
    context = message.get('context_token')
    items = message.get('item_list')
    if not isinstance(context, str) or not 0 < len(context) <= 65536 or not isinstance(items, list) or not items:
        return None
    if any(not isinstance(i, dict) or i.get('type') != 1 for i in items):
        return None  # This cloud backend deliberately accepts text only.
    if any(not isinstance(i.get('text_item'), dict) for i in items):
        return None
    texts = [i['text_item'].get('text', '') for i in items]
    if any(not isinstance(t, str) for t in texts):
        return None
    text = '\n'.join(texts).strip()
    if not text or len(text) > 35000:
        return None
    return str(message['message_id']), context, text


class Store:
    def __init__(self, config):
        config.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(config.state_dir, 0o700)
        self.lock = open(config.state_dir / 'relay.lock', 'a')
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close()
            raise SafeError('Another bridge owns this state directory') from None
        self.db = sqlite3.connect(config.state_dir / 'relay.sqlite3')
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS jobs (
          id TEXT PRIMARY KEY, context TEXT NOT NULL, text TEXT NOT NULL,
          client TEXT NOT NULL, phase TEXT NOT NULL, ts TEXT,
          deadline REAL, poll_at REAL DEFAULT 0, cursor TEXT DEFAULT '');
        CREATE TABLE IF NOT EXISTS replies (
          job TEXT, ts TEXT, digest TEXT, PRIMARY KEY(job,ts,digest));
        CREATE TABLE IF NOT EXISTS outbox (
          id TEXT PRIMARY KEY, job TEXT NOT NULL, text TEXT NOT NULL,
          phase TEXT NOT NULL DEFAULT 'queued');
        ''')
        binding = self.get('binding')
        if binding and binding != config.binding():
            raise SafeError('State belongs to different identities; use a new state directory')
        with self.db:
            self.put('binding', config.binding())
            # An in-flight mutation is ambiguous after a crash. Never replay it.
            self.db.execute("UPDATE jobs SET phase='uncertain' WHERE phase='posting'")
            self.db.execute("UPDATE outbox SET phase='uncertain' WHERE phase='sending'")
            self.db.execute("UPDATE jobs SET cursor=''")

    def get(self, key, default=''):
        row = self.db.execute('SELECT value FROM meta WHERE key=?', (key,)).fetchone()
        return row[0] if row else default

    def put(self, key, value):
        self.db.execute('INSERT OR REPLACE INTO meta VALUES (?,?)', (key, str(value)))

    def close(self):
        self.db.close()
        self.lock.close()


class Bridge:
    def __init__(self, config, store, slack, wechat, clock=time.time):
        self.c, self.s, self.slack, self.wechat, self.clock = config, store, slack, wechat, clock
        with self.s.db:
            for job in self.s.db.execute("SELECT id FROM jobs WHERE phase='uncertain'").fetchall():
                self.enqueue(job['id'], 'slack-uncertain', '发送到 Slack 的结果不确定，已停止自动重试以免重复执行。请检查 Slack；云端管理员可关联已有消息。')

    def ingest(self, response):
        messages = response.get('msgs', [])
        cursor = response.get('get_updates_buf', self.s.get('cursor'))
        if not isinstance(messages, list) or not isinstance(cursor, str) or len(cursor) > 65536:
            raise SafeError('Invalid WeChat update envelope')
        with self.s.db:
            for message in messages:
                accepted = accept(message, self.c)
                if not accepted:
                    continue
                mid, context, text = accepted
                if self.s.db.execute('SELECT 1 FROM jobs WHERE id=?', (mid,)).fetchone():
                    continue
                if self.s.db.execute('SELECT count(*) FROM jobs').fetchone()[0] >= 10000:
                    print('State retention limit reached; new ingestion paused; inspect existing jobs', flush=True)
                    return
                count = self.s.db.execute("SELECT count(*) FROM jobs WHERE phase IN ('queued','posting','watching')").fetchone()[0]
                if count >= 32:
                    return  # Commit accepted prefix, retain cursor so remaining work is replayed.
                self.s.db.execute('INSERT INTO jobs(id,context,text,client,phase) VALUES (?,?,?,?,?)',
                                  (mid, context, text, str(uuid.uuid4()), 'queued'))
            self.s.put('cursor', cursor)

    def post_one(self):
        job = self.s.db.execute("SELECT * FROM jobs WHERE phase='queued' ORDER BY rowid LIMIT 1").fetchone()
        if not job or self.clock() < float(self.s.get('post_after', '0')):
            return
        with self.s.db:
            self.s.db.execute("UPDATE jobs SET phase='posting' WHERE id=?", (job['id'],))
            self.s.put('post_after', self.clock() + 2)
        try:
            ts = self.slack.post(job['text'], job['client'])
        except RateLimited as exc:
            with self.s.db:
                self.s.db.execute("UPDATE jobs SET phase='queued' WHERE id=?", (job['id'],))
                self.s.put('post_after', self.clock() + exc.seconds)
            return
        except SafeError:
            with self.s.db:
                self.s.db.execute("UPDATE jobs SET phase='uncertain' WHERE id=?", (job['id'],))
                self.enqueue(job['id'], 'slack-uncertain', '发送到 Slack 的结果不确定，已停止自动重试以免重复执行。请检查 Slack；云端管理员可关联已有消息。')
            return
        with self.s.db:
            self.s.db.execute("UPDATE jobs SET phase='watching',ts=?,deadline=?,text='' WHERE id=?",
                              (ts, self.clock() + self.c.window, job['id']))

    def enqueue(self, job, event, text):
        # Stable IDs support diagnosis; no assumption that WeChat deduplicates retries.
        for index in range(0, len(text), 3500):
            client = hashlib.sha256(f'{job}:{event}:{index}'.encode()).hexdigest()[:32]
            self.s.db.execute('INSERT OR IGNORE INTO outbox(id,job,text) VALUES (?,?,?)',
                              (client, job, text[index:index + 3500]))

    def poll_one(self):
        now = self.clock()
        with self.s.db:
            for job in self.s.db.execute("SELECT * FROM jobs WHERE phase='watching' AND deadline<=?", (now,)).fetchall():
                self.s.db.execute("UPDATE jobs SET phase='paused' WHERE id=?", (job['id'],))
                self.enqueue(job['id'], 'window-' + str(job['deadline']),
                             '此消息的微信回传观察窗口已到期，任务是否完成仍以 Slack 为准。关联已保留，可在云端 resume 继续回传；也可以直接在 Slack 查看或继续聊天。')
        if now < float(self.s.get('poll_after', '0')):
            return
        job = self.s.db.execute("SELECT * FROM jobs WHERE phase='watching' ORDER BY poll_at,rowid LIMIT 1").fetchone()
        if not job:
            return
        with self.s.db:
            self.s.put('poll_after', now + 65)  # Global method budget, including pagination/restarts.
            self.s.db.execute('UPDATE jobs SET poll_at=? WHERE id=?', (now, job['id']))
        try:
            response = self.slack.replies(job['ts'], job['cursor'])
        except InvalidCursor:
            with self.s.db:
                self.s.db.execute("UPDATE jobs SET cursor='' WHERE id=?", (job['id'],))
            return
        except RateLimited as exc:
            with self.s.db:
                self.s.put('poll_after', self.clock() + exc.seconds)
            return
        messages = response.get('messages')
        metadata = response.get('response_metadata', {})
        if not isinstance(metadata, dict):
            raise SafeError('Invalid Slack response metadata')
        cursor = metadata.get('next_cursor', '')
        if not isinstance(messages, list) or not isinstance(cursor, str) or len(cursor) > 4096:
            raise SafeError('Invalid Slack thread response')
        if response.get('has_more') and not cursor:
            raise SafeError('Slack pagination missing cursor')
        with self.s.db:
            for msg in messages:
                if not isinstance(msg, dict):
                    continue
                ts, text = msg.get('ts'), msg.get('text')
                if (not valid_ts(ts) or ts == job['ts'] or msg.get('thread_ts') != job['ts']
                        or msg.get('user') != self.c.dot or msg.get('bot_id') != self.c.bot
                        or msg.get('subtype') not in (None, 'bot_message')
                        or not isinstance(text, str) or not text.strip()):
                    continue
                digest = hashlib.sha256(text.encode()).hexdigest()
                if self.s.db.execute('SELECT 1 FROM replies WHERE job=? AND ts=? AND digest=?',
                                     (job['id'], ts, digest)).fetchone():
                    continue
                edited = self.s.db.execute('SELECT 1 FROM replies WHERE job=? AND ts=?', (job['id'], ts)).fetchone()
                self.s.db.execute('INSERT INTO replies VALUES (?,?,?)', (job['id'], ts, digest))
                # Poll snapshots, never identify a progress/final message heuristically.
                prefix = '[Slack 消息更新]\n' if edited else '[Slack 回复]\n'
                suffix = '\n[消息过长，已截断；完整内容请查看 Slack]' if len(text) > 200000 else ''
                self.enqueue(job['id'], ts + ':' + digest, prefix + text[:200000] + suffix)
            self.s.db.execute('UPDATE jobs SET cursor=? WHERE id=?', (cursor, job['id']))

    def deliver_one(self):
        row = self.s.db.execute("SELECT o.*,j.context,j.client FROM outbox o JOIN jobs j ON j.id=o.job WHERE o.phase='queued' ORDER BY o.rowid LIMIT 1").fetchone()
        if not row or self.clock() < float(self.s.get('send_after', '0')):
            return
        with self.s.db:
            self.s.db.execute("UPDATE outbox SET phase='sending' WHERE id=?", (row['id'],))
            self.s.put('send_after', self.clock() + 1)
        try:
            self.wechat.send(row['context'], row['text'], row['id'], row['client'])
        except RateLimited as exc:
            with self.s.db:
                self.s.db.execute("UPDATE outbox SET phase='queued' WHERE id=?", (row['id'],))
                self.s.put('send_after', self.clock() + exc.seconds)
            return
        except SafeError:
            with self.s.db:
                self.s.db.execute("UPDATE outbox SET phase='uncertain' WHERE id=?", (row['id'],))
            print('WeChat delivery uncertain; inspect status and Slack before manual recovery', flush=True)
            return
        with self.s.db:
            self.s.db.execute("UPDATE outbox SET phase='sent',text='' WHERE id=?", (row['id'],))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', choices=['slack'], default='slack')
    parser.add_argument('command', choices=['run', 'check', 'status', 'resume', 'link'], nargs='?', default='run')
    parser.add_argument('--job', help='WeChat message ID from status')
    parser.add_argument('--thread', help='Verified existing Slack root timestamp for an uncertain send')
    args = parser.parse_args()
    os.umask(0o077)
    config = Config(os.environ)
    store = Store(config)
    try:
        slack, wechat = Slack(config, HTTP()), WeChat(config, HTTP())
        if args.command == 'status':
            for row in store.db.execute('SELECT id,phase,ts,deadline FROM jobs ORDER BY rowid'):
                print(dict(row))
            for row in store.db.execute("SELECT id,job,phase FROM outbox WHERE phase!='sent'"):
                print(dict(row))
            return
        slack.validate()
        if args.command == 'check':
            print('Slack identities verified. No message sent; WeChat credentials not verified.')
            return
        if args.command in ('resume', 'link'):
            job = store.db.execute('SELECT * FROM jobs WHERE id=?', (args.job,)).fetchone()
            if not job:
                raise SafeError('Unknown job')
            ts = job['ts']
            if args.command == 'link':
                if job['phase'] != 'uncertain' or not valid_ts(args.thread):
                    raise SafeError('link requires uncertain job and valid --thread')
                if time.time() < float(store.get('poll_after', '0')):
                    raise SafeError('Slack read budget reserved; wait at least 65 seconds')
                with store.db:
                    store.put('poll_after', time.time() + 65)
                result = slack.replies(args.thread, '')
                roots = [m for m in result.get('messages', []) if m.get('ts') == args.thread]
                if len(roots) != 1 or roots[0].get('user') != config.owner or roots[0].get('text') != job['text']:
                    raise SafeError('Slack root does not match original owner/text')
                ts = args.thread
            elif job['phase'] != 'paused':
                raise SafeError('resume requires paused job')
            with store.db:
                store.db.execute("UPDATE jobs SET phase='watching',ts=?,deadline=?,cursor='',text='' WHERE id=?",
                                 (ts, time.time() + config.window, job['id']))
            print('Thread observation resumed; no task reposted')
            return
        bridge = Bridge(config, store, slack, wechat)
        print('Cloud Slack relay running; text only; existing dot DM verified', flush=True)
        # Independent read loop avoids a long poll delaying Slack delivery.
        import threading
        import queue
        inbox = queue.Queue(maxsize=1)
        stop = threading.Event()
        def read_updates():
            cursor = initial_cursor
            while not stop.is_set():
                try:
                    response = wechat.updates(cursor)
                    ack = queue.Queue(maxsize=1)
                    inbox.put((response, ack))
                    new_cursor = ack.get()
                    if new_cursor == cursor:
                        stop.wait(30)
                    cursor = new_cursor
                except SafeError as exc:
                    print(str(exc), flush=True)
                    stop.wait(exc.seconds if isinstance(exc, RateLimited) else 30)
        initial_cursor = store.get('cursor')
        threading.Thread(target=read_updates, daemon=True).start()
        try:
            while True:
                try:
                    response, ack = inbox.get_nowait()
                except queue.Empty:
                    pass
                else:
                    bridge.ingest(response)
                    ack.put(store.get('cursor'))
                for action in (bridge.post_one, bridge.poll_one, bridge.deliver_one):
                    try:
                        action()
                    except SafeError as exc:
                        print(str(exc), flush=True)
                time.sleep(1)
        finally:
            stop.set()
    finally:
        store.close()


if __name__ == '__main__':
    try:
        main()
    except SafeError as exc:
        print('Bridge stopped: ' + str(exc), file=sys.stderr)
        sys.exit(1)
    except sqlite3.Error:
        print('Bridge stopped: private state failed; inspect storage before restarting.', file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        pass
