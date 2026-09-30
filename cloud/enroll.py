#!/usr/bin/env python3
"""Explicit, interactive WeChat enrollment. Never run automatically on bridge startup."""
import argparse
import base64
import getpass
import json
import os
from pathlib import Path
import time
import urllib.parse
from bridge import HTTP, HTTPStatusError, SafeError, trusted_wechat


class Enrollment:
    def __init__(self, http, render, verify, confirm_owner, sleep=time.sleep):
        self.http, self.render, self.verify = http, render, verify
        self.confirm_owner, self.sleep = confirm_owner, sleep

    def run(self):
        headers = {'iLink-App-Id': 'bot', 'iLink-App-ClientVersion': '132102',
                   'Content-Type': 'application/json', 'AuthorizationType': 'ilink_bot_token',
                   'X-WECHAT-UIN': base64.b64encode(str(int.from_bytes(os.urandom(4), 'big')).encode()).decode()}
        redirects = 0
        for _ in range(4):
            url = 'https://ilinkai.weixin.qq.com/ilink/bot/get_bot_qrcode?bot_type=3'
            try:
                # Current Tencent protocol and the original Swift client use POST.
                qr = self.http.request(url, headers, {'local_token_list': []}, timeout=15)
            except HTTPStatusError as exc:
                if exc.status != 405:
                    raise
                # Some deployed endpoints still expose GET. Only an explicit method
                # rejection permits this fallback; never retry ambiguous failures.
                qr = self.http.request(url, {'iLink-App-Id': 'bot',
                                            'iLink-App-ClientVersion': '132102'}, timeout=15)
            identifier, content = qr.get('qrcode'), qr.get('qrcode_img_content')
            if any(not isinstance(v, str) or not 0 < len(v) <= 4096 for v in (identifier, content)):
                raise SafeError('Invalid QR response')
            self.render(content)
            base, code = 'https://ilinkai.weixin.qq.com', None
            while True:
                query = {'qrcode': identifier}
                if code:
                    query['verify_code'] = code
                response = self.http.request(base + '/ilink/bot/get_qrcode_status?' + urllib.parse.urlencode(query),
                                             {'iLink-App-Id': 'bot', 'iLink-App-ClientVersion': '132102'}, timeout=40)
                code = None
                status = response.get('status')
                if status in ('wait', 'scaned'):
                    pass
                elif status == 'need_verifycode':
                    code = self.verify().strip()
                    if not code or len(code) > 64:
                        raise SafeError('Verification code missing or too long')
                elif status == 'expired':
                    break
                elif status == 'scaned_but_redirect':
                    redirects += 1
                    host = response.get('redirect_host')
                    if redirects > 3 or not isinstance(host, str):
                        raise SafeError('Too many or invalid login redirects')
                    base = trusted_wechat('https://' + host)
                elif status == 'confirmed':
                    token, account, owner = (response.get(k) for k in ('bot_token', 'ilink_bot_id', 'ilink_user_id'))
                    if (not isinstance(token, str) or not 0 < len(token) <= 65536
                            or any(not isinstance(v, str) or not 0 < len(v) <= 4096 for v in (account, owner))):
                        raise SafeError('Login lacks credentials or owner ID; refusing first-message owner binding')
                    raw = response.get('baseurl') or 'https://ilinkai.weixin.qq.com'
                    if not isinstance(raw, str):
                        raise SafeError('Invalid login endpoint')
                    base = trusted_wechat(raw if '://' in raw else 'https://' + raw)
                    if not self.confirm_owner(owner):
                        raise SafeError('Owner confirmation declined; credentials not saved')
                    return {'bot_token': token, 'ilink_bot_id': account, 'ilink_user_id': owner, 'baseurl': base}
                else:
                    raise SafeError('Login blocked, already bound, or unsupported status; restart approved sign-in')
                self.sleep(1)
        raise SafeError('QR login repeatedly expired')


def save_credentials(path, credentials):
    # O_EXCL refuses overwrite/symlink target; explicit separate enrollment for renewal.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(credentials, file)
        file.flush()
        os.fsync(file.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, help='New private JSON credential file (never overwritten)')
    args = parser.parse_args()
    os.umask(0o077)
    path = Path(args.output)
    if path.exists() or not path.parent.is_dir():
        raise SafeError('Choose a new credential file in an existing private directory')
    try:
        import qrcode
    except ImportError:
        raise SafeError('Install optional enrollment dependency qrcode==8.2 first') from None
    def render(content):
        qr = qrcode.QRCode(border=2)
        qr.add_data(content)
        qr.make(fit=True)
        print('Scan this QR with your own WeChat and confirm on your phone. Do not share it.')
        qr.print_ascii(invert=True)
    def confirm(owner):
        print('WeChat returned owner ID:', owner)
        return input('Confirm this is the account you just approved by typing YES: ').strip() == 'YES'
    credentials = Enrollment(HTTP(), render,
                             lambda: getpass.getpass('WeChat verification code: '), confirm).run()
    save_credentials(path, credentials)
    print('Credentials saved privately. Set WECHAT_CREDENTIALS_FILE to this file; never paste it into chat.')


if __name__ == '__main__':
    try:
        main()
    except (SafeError, OSError, EOFError) as exc:
        print(str(exc) if isinstance(exc, SafeError) else 'Enrollment stopped; credentials not printed')
        raise SystemExit(1)
    except KeyboardInterrupt:
        raise SystemExit(130)
