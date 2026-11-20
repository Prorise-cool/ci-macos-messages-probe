#!/usr/bin/env python3
"""
messages_login_send.py — reusable Messages.app driver for a headless macOS CI runner.

Design goals
  * work in a GitHub Actions `macos-15` runner where the GUI session is not "logged in"
    interactively (loginwindow owns the console);
  * never depends on AppleEvents working — falls back to CGWindowList / AXUIElement /
    CGEvent injection, and to chat.db for reading replies;
  * never sends anything unless `--confirm-send` is passed (a bare Return in a chat window
    would actually deliver the message).

Subcommands
  probe                       print environment / trust / window / account observation
  login  --apple-id A [--password P] [--code C] [--code-file F]
                              drive the Messages sign-in sheet (Sign in to iMessage)
  compose --address +1... --body TXT
                              open sms://open?address=...&body=... and type the text
                              (opens the compose window; does NOT press Return)
  send                        press Return in the frontmost Messages chat window
                              REQUIRES --confirm-send, and a --allow <address> whitelist
  read   [--limit N]          dump recent messages from ~/Library/Messages/chat.db
  status                      one-line JSON verdict of what layer works

Everything it learns is written to JSON logs under --outdir (default ./msgout).
"""
import argparse, json, os, re, shutil, sqlite3, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
CHAT_DB = os.path.expanduser('~/Library/Messages/chat.db')
SELF_TCC = os.path.expanduser('~/Library/Application Support/com.apple.TCC/TCC.db')


# ---------------------------------------------------------------- small helpers
def run(cmd, timeout=90, input_text=None):
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True,
                           text=True, timeout=timeout, input=input_text)
        return {'rc': p.returncode, 'out': p.stdout.strip(), 'err': p.stderr.strip()}
    except subprocess.TimeoutExpired:
        return {'rc': 'timeout', 'out': '', 'err': 'timeout after %ss' % timeout}
    except Exception as e:  # noqa
        return {'rc': 'err', 'out': '', 'err': repr(e)}


def cgui(*args, timeout=60):
    """cgui helper built from cgui.swift next to this script."""
    exe = os.path.join(HERE, 'cgui')
    if not os.path.exists(exe):
        return {'rc': 'missing', 'out': '', 'err': 'cgui not built'}
    return run([exe] + [str(a) for a in args], timeout=timeout)


def osa(script, timeout=45):
    """AppleScript with a hard timeout; -1712 is reported, never retried by us."""
    return run(['osascript', '-e', script], timeout=timeout)


def log(outdir, name, obj):
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, name)
    with open(path, 'w') as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
    return path


def shot(outdir, name):
    os.makedirs(outdir, exist_ok=True)
    p = os.path.join(outdir, name + '.png')
    r = run(['screencapture', '-x', p], timeout=60)
    res = {'path': p, 'rc': r['rc'], 'err': r['err']}
    ocr = os.path.join(HERE, 'ocr')
    if r['rc'] == 0 and os.path.exists(ocr):
        o = run([ocr, p], timeout=120)
        res['ocr'] = (o['out'] or '')[-3000:]
        with open(os.path.join(outdir, name + '.ocr.txt'), 'w') as f:
            f.write(o['out'])
    return res


def windows():
    r = cgui('list')
    out = []
    for line in (r['out'] or '').splitlines():
        kv = dict(re.findall(r'(\w+)=([^\t]*)', line))
        if kv:
            out.append(kv)
    return {'rc': r['rc'], 'windows': out, 'raw': r['out']}


def msg_windows(win):
    return [w for w in win['windows'] if 'Messages' in (w.get('owner') or '')]


def front_pid(win):
    for w in msg_windows(win):
        if w.get('pid'):
            return int(w['pid'])
    return None


def chat_db_state():
    st = {'path': CHAT_DB, 'exists': os.path.exists(CHAT_DB)}
    if not st['exists']:
        return st
    try:
        con = sqlite3.connect('file:%s?mode=ro' % CHAT_DB, uri=True, timeout=10)
        cur = con.cursor()
        st['tables'] = [r[0] for r in cur.execute(
            "select name from sqlite_master where type='table' order by 1")]
        for t in ('message', 'handle', 'chat', 'chat_message_join'):
            if t in st['tables']:
                st['count_' + t] = cur.execute('select count(*) from %s' % t).fetchone()[0]
        if 'message' in st['tables']:
            st['message_columns'] = [r[1] for r in cur.execute('pragma table_info(message)')]
        con.close()
    except Exception as e:  # noqa
        st['error'] = repr(e)
    return st


def read_messages(limit=20):
    out = {'limit': limit, 'rows': [], 'error': None}
    if not os.path.exists(CHAT_DB):
        out['error'] = 'chat.db missing'
        return out
    try:
        con = sqlite3.connect('file:%s?mode=ro' % CHAT_DB, uri=True, timeout=10)
        cur = con.cursor()
        q = ("select m.ROWID, m.date, m.is_from_me, m.is_sent, m.text, h.id "
             "from message m left join handle h on h.ROWID = m.handle_id "
             "order by m.ROWID desc limit ?")
        for rid, date, from_me, is_sent, text, handle in cur.execute(q, (limit,)):
            out['rows'].append({'rowid': rid, 'date': date, 'is_from_me': from_me,
                                'is_sent': is_sent, 'text': text, 'handle': handle})
        con.close()
    except Exception as e:  # noqa
        out['error'] = repr(e)
    return out


def tcc_rows():
    """Which clients already hold Automation / Accessibility / FullDiskAccess grants."""
    res = {'user_db_readable': False, 'rows': []}
    if os.path.exists(SELF_TCC):
        try:
            con = sqlite3.connect('file:%s?mode=ro' % SELF_TCC, uri=True, timeout=10)
            res['rows'] = [dict(zip(('service', 'client', 'client_type', 'auth_value'), r))
                           for r in con.execute(
                               'select service, client, client_type, auth_value from access')]
            res['user_db_readable'] = True
            con.close()
        except Exception as e:  # noqa
            res['error'] = repr(e)
    else:
        res['error'] = 'TCC.db unreachable (TCC / FDA not granted to this process)'
    return res


# ---------------------------------------------------------------- subcommands
def cmd_probe(a):
    res = {'ts': time.time()}
    res['env'] = {
        'sw_vers': run(['sw_vers'])['out'],
        'arch': run(['uname', '-m'])['out'],
        'who': run(['who'])['out'],
        'sessionname': os.environ.get('SESSIONNAME'),
    }
    con = run(['/usr/sbin/scutil'], input_text='show State:/Users/ConsoleUser\n')
    res['console_user'] = con['out']
    res['tcc'] = tcc_rows()
    res['cgui_trusted'] = cgui('ax')['out']
    res['window_list_before'] = windows()
    res['launch'] = run(['open', '-a', 'Messages'])
    time.sleep(8)
    res['pgrep'] = run(['pgrep', '-lf', 'Messages|imagent'])['out']
    win = windows()
    res['window_list_after'] = win
    res['screencapture_launch'] = shot(a.outdir, 'probe_messages_launch')
    res['appleevents'] = {
        'version': osa('tell application "Messages" to get version'),
        'services': osa('with timeout of 10 seconds\n'
                        'tell application "Messages" to get name of every service\nend timeout'),
        'accounts': osa('with timeout of 10 seconds\n'
                        'tell application "Messages" to get name of every account\nend timeout'),
        'activate': osa('tell application "Messages" to activate'),
    }
    res['system_events'] = {
        'ui_enabled': osa('tell application "System Events" to get UI elements enabled'),
        'processes': osa('with timeout of 10 seconds\n'
                         'tell application "System Events" to get name of every process '
                         'whose background only is false\nend timeout'),
        'keystroke': osa('tell application "System Events" to keystroke "a"'),
    }
    pid = front_pid(win)
    res['messages_pid'] = pid
    if pid:
        res['axdump'] = cgui('axdump', pid, 4)['out'][:20000]
    res['chat_db'] = chat_db_state()
    res['chat_db_rows'] = read_messages(5)
    res['schemes'] = {'shortcuts': run(['which', 'shortcuts'])['out'],
                      'cliclick': run(['which', 'cliclick'])['out']}
    res['verdict'] = verdict(res)
    p = log(a.outdir, 'probe.json', res)
    print(json.dumps({k: res[k] for k in ('verdict', 'messages_pid', 'chat_db')}, indent=2, ensure_ascii=False)[:4000])
    print('full log:', p)
    return 0


def verdict(res):
    ae = res.get('appleevents', {})
    ok_ae = any(isinstance(v, dict) and v.get('rc') == 0 and v.get('out') for v in ae.values())
    se = res.get('system_events', {})
    se_ok = any(isinstance(v, dict) and v.get('rc') == 0 for v in se.values())
    trusted = 'AXIsProcessTrusted=true' in (res.get('cgui_trusted') or '')
    has_win = bool(msg_windows(res.get('window_list_after') or {'windows': []}))
    db = res.get('chat_db') or {}
    return {
        'appleevent_ok': ok_ae,
        'system_events_ok': se_ok,
        'ax_trusted': trusted,
        'messages_window': has_win,
        'chat_db_readable': bool(db.get('exists')) and 'error' not in db,
        'chat_db_messages': db.get('count_message'),
        'control_channel': ('appleevent' if ok_ae else
                            'cgwindow+chatdb' if has_win else 'none-detected'),
    }


def _send_text(text):
    """Type printable text via CGEvent unicode injection (no AX needed)."""
    return cgui('key', text)


def _key(code):
    return cgui('keycode', code)


def _click(x, y):
    return cgui('click', x, y)


KEY_TAB, KEY_RETURN, KEY_ESC = 48, 36, 53


def cmd_login(a):
    res = {'ts': time.time(), 'steps': []}

    def step(name, obj):
        obj = {'step': name, **obj}
        res['steps'].append(obj)
        print('[%s] %s' % (name, {k: (v['out'] if isinstance(v, dict) else v) for k, v in obj.items()
                                 if k != 'step'}))
        return obj

    run(['open', '-a', 'Messages'])
    time.sleep(6)
    win = windows()
    step('launch', {'windows': msg_windows(win)})
    if not msg_windows(win):
        step('no_window', {'error': 'Messages has no window; cannot drive the sign-in sheet'})
        log(a.outdir, 'login.json', res)
        return 3
    pid = front_pid(win)
    step('front', cgui('front', 'Messages'))
    time.sleep(2)
    ax = cgui('axdump', pid, 6)['out'] if pid else ''
    open(os.path.join(a.outdir, 'login_ax_before.txt'), 'w').write(ax)
    sh = shot(a.outdir, 'login_01_start')
    step('screenshot', sh)

    signed_in = 'Sign in' not in ax and 'sign in' not in (sh.get('ocr') or '').lower() \
        and ('iMessage' in ax or 'iMessage' in (sh.get('ocr') or ''))
    if signed_in:
        step('already_signed_in', {'ax_head': ax[:500]})
        log(a.outdir, 'login.json', res)
        return 0

    # The sign-in sheet: click the "Sign in" button if we can find it, else use keyboard.
    # AX tree gives positions like pos=<x>,<y> size=<w>,<h> for buttons; we click the first
    # button whose title/desc mentions Sign in.
    clicked = False
    for m in re.finditer(r'role=AXButton[^\n]*?(?:title|desc)=([^\n]*?)pos=[^\n]*?([\d.]+),([\d.]+)'
                         r'[^\n]*?size=([\d.]+),([\d.]+)', ax):
        label = m.group(1)
        if 'sign' in label.lower():
            x = float(m.group(2)) + float(m.group(4)) / 2
            y = float(m.group(3)) + float(m.group(5)) / 2
            step('click_signin', _click(x, y))
            clicked = True
            break
    if not clicked:
        step('click_signin', {'note': 'no AXButton tagged Sign in; relying on field focus + typing'})
    time.sleep(3)

    # Fill Apple ID then Tab to password then Tab to submit.
    step('type_apple_id', _send_text(a.apple_id))
    time.sleep(1)
    step('tab', _key(KEY_TAB))
    time.sleep(1)
    if a.password:
        step('type_password', _send_text(a.password))
        time.sleep(1)
        step('tab2', _key(KEY_TAB))
        time.sleep(1)
        step('submit', _key(KEY_RETURN))
        time.sleep(12)
    sh = shot(a.outdir, 'login_02_submit')
    step('screenshot_after_submit', sh)
    ax = cgui('axdump', pid, 6)['out'] if pid else ''
    open(os.path.join(a.outdir, 'login_ax_after_submit.txt'), 'w').write(ax)

    # 2FA: a sheet with 6 boxes or a single field asking for the code.
    code = a.code
    if a.code_file and os.path.exists(a.code_file):
        code = open(a.code_file).read().strip()
    if code:
        step('type_2fa', _send_text(code))
        time.sleep(1)
        step('submit_2fa', _key(KEY_RETURN))
        time.sleep(15)
        step('screenshot_after_2fa', shot(a.outdir, 'login_03_2fa'))
    else:
        step('no_2fa_code', {'note': 'pass --code / --code-file; a human read of the SMS inbox '
                                     'is required (we never guess codes)'})

    res['final_state'] = {
        'signed_in_guess': re.search(r'iMessage|Message', ax or '') is not None,
        'ax_tail': (ax or '')[-4000:],
        'chat_db': chat_db_state(),
    }
    log(a.outdir, 'login.json', res)
    return 0


def cmd_compose(a):
    res = {'ts': time.time()}
    url = 'sms://open?address=%s&body=%s' % (a.address, a.body.replace(' ', '%20').replace('&', '%26'))
    res['url'] = url
    res['open'] = run(['open', url])
    time.sleep(6)
    win = windows()
    res['windows'] = msg_windows(win)
    if not msg_windows(win):
        res['error'] = 'no Messages window after URL open'
        log(a.outdir, 'compose.json', res)
        return 3
    pid = front_pid(win)
    res['front'] = cgui('front', 'Messages')
    time.sleep(2)
    if a.type_text:
        # Type into the message field of the focused chat window (no Return).
        res['typed'] = _send_text(a.type_text)
        time.sleep(2)
    res['screenshot'] = shot(a.outdir, 'compose_01')
    res['chat_db'] = chat_db_state()
    res['draft_rows'] = read_messages(5)
    log(a.outdir, 'compose.json', res)
    print(json.dumps(res, indent=2, ensure_ascii=False)[:4000])
    return 0


def cmd_send(a):
    if not a.confirm_send:
        print('refusing: pass --confirm-send to actually press Return (this delivers!)')
        return 2
    if a.allow and a.address and a.address not in a.allow:
        print('refusing: address %s not in --allow whitelist' % a.address)
        return 2
    win = windows()
    if not msg_windows(win):
        print('refusing: no Messages window')
        return 3
    cgui('front', 'Messages')
    time.sleep(1)
    r = _key(KEY_RETURN)
    time.sleep(4)
    res = {'return': r, 'windows': msg_windows(windows()),
           'screenshot': shot(a.outdir, 'send_01'),
           'chat_db': chat_db_state(), 'rows': read_messages(5)}
    log(a.outdir, 'send.json', res)
    print(json.dumps(res, indent=2, ensure_ascii=False)[:4000])
    return 0


def cmd_read(a):
    res = read_messages(a.limit)
    log(a.outdir, 'read.json', res)
    print(json.dumps(res, indent=2, ensure_ascii=False)[:8000])
    return 0


def cmd_status(a):
    win = windows()
    ae = osa('with timeout of 8 seconds\ntell application "Messages" to get name\nend timeout')
    st = {
        'appleevent_ok': ae['rc'] == 0 and bool(ae['out']),
        'appleevent_err': ae['err'] or None,
        'messages_window': bool(msg_windows(win)),
        'chat_db': chat_db_state(),
    }
    st['channel'] = 'appleevent' if st['appleevent_ok'] else (
        'cgwindow+chatdb' if st['messages_window'] else 'none')
    print(json.dumps(st, indent=2, ensure_ascii=False))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['probe', 'login', 'compose', 'send', 'read', 'status'])
    ap.add_argument('--outdir', default='./msgout')
    ap.add_argument('--apple-id')
    ap.add_argument('--password')
    ap.add_argument('--code')
    ap.add_argument('--code-file')
    ap.add_argument('--address', default='+19496788958')
    ap.add_argument('--body', default='hello')
    ap.add_argument('--type-text', default=None,
                    help='text to type into the compose field (never auto-sent)')
    ap.add_argument('--limit', type=int, default=20)
    ap.add_argument('--confirm-send', action='store_true')
    ap.add_argument('--allow', nargs='*', default=['+19496788958'])
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    fn = {'probe': cmd_probe, 'login': cmd_login, 'compose': cmd_compose,
          'send': cmd_send, 'read': cmd_read, 'status': cmd_status}[a.cmd]
    return fn(a)


if __name__ == '__main__':
    sys.exit(main())
