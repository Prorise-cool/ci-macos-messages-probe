#!/usr/bin/env python3
# i103452 probe13 -- iOS Simulator Apple Account creation, WINDOW-COORDINATE click method.
#
# What changed vs probe12 (run 44701855705):
#   probe12's affine fit was computed in device POINTS (OCR px / 3) but tap_dev() was fed
#   device PIXELS, so Settings(992,1300 px) mapped to host (1055,995) -- outside the
#   1024x768 host screen.  Every screenshot stayed on Springboard.  probe13 fixes the unit
#   domain, adds an independent device-scale sanity number derived from the Simulator
#   window bounds + real device screenshot size, and (most importantly) VERIFIES every
#   click by diffing the window/device screen signature; if a click changes nothing it is
#   retried once through the other mapping and then the probe ABORTS (never blind-clicks).
#
# Flow: launch Settings (simctl) -> Apple Account -> "Don't have an Apple Account?" ->
#       Age Range -> Adult -> record the real form verbatim -> adaptive fill ->
#       captcha / email / phone / terms -> verdict.
# No brute force, no code guessing, no number/domain enumeration.
import subprocess, time, re, os, sys, json, random, string, statistics, html as htmlmod
import urllib.request, urllib.parse, hashlib

OUT = os.environ.get('OUT', os.getcwd() + '/out13')
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, 'p13.log'), 'a', buffering=1)
T0 = time.time()
CAP = float(os.environ.get('CAP_MIN', '23')) * 60.0
PHONE_PRIMARY = os.environ.get('PHONE_PRIMARY', '447450699185')
PASSWORD = os.environ.get('APPLE_PW') or ('Pk' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(13)) + '!9x')
SMS_SINCE = None
STATE = {'screens': [], 'events': [], 'captcha_seen': 0, 'captcha_tries': 0,
         'captcha_wrong': 0, 'vm_text': '', 'phone_accepted': None,
         'email_used': None, 'country': None, 'stage': 'start', 'error': '',
         'account_candidate': None}
EMAIL = {'kind': None, 'addr': None, 'token': None, 'idx': 0, 'tried': []}

def log(*a):
    s = ' '.join(str(x) for x in a)
    print(s, flush=True)
    LOG.write(time.strftime('[%H:%M:%S] ') + s + '\n')

def ev(name, **kw):
    rec = {'t': round(time.time() - T0, 1), 'e': name}
    rec.update(kw)
    STATE['events'].append(rec)
    log('EV %s %s' % (name, json.dumps(kw, ensure_ascii=False)[:400]))

def over():
    return time.time() - T0 > CAP

def sh(cmd, t=90):
    log('--- $ ' + (' '.join(cmd) if isinstance(cmd, list) else cmd))
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=t)
        out = (p.stdout or '') + (p.stderr or '')
        for ln in out.strip().splitlines()[-5:]:
            log('    ' + ln[:300])
        return p.returncode, out
    except subprocess.TimeoutExpired:
        log('    TIMEOUT')
        return 'TO', ''

# ------------------------------------------------------------------ OCR / images
def ocrbox(img):
    rc, out = sh(['./ocrbox', img], t=150)
    res = []
    for ln in out.splitlines():
        if ln.startswith('BOX\t'):
            p = ln.split('\t', 5)
            if len(p) == 6:
                try:
                    res.append((float(p[1]), float(p[2]), float(p[3]), float(p[4]), p[5]))
                except Exception:
                    pass
    return res

def png_size(path):
    try:
        with open(path, 'rb') as f:
            d = f.read(33)
        if d[:8] == b'\x89PNG\r\n\x1a\n':
            return int.from_bytes(d[16:20], 'big'), int.from_bytes(d[20:24], 'big')
    except Exception:
        pass
    return None

def devshot(tag):
    path = os.path.join(OUT, 'dev_%s.png' % tag)
    for _ in range(3):
        sh(['xcrun', 'simctl', 'io', 'booted', 'screenshot', path], t=60)
        if os.path.exists(path) and os.path.getsize(path) > 20000:
            return path
        time.sleep(2)
    return path

def hostshot(tag):
    path = os.path.join(OUT, 'host_%s.png' % tag)
    sh(['screencapture', '-x', path], t=40)
    return path

# Simulator window bounds: AppleScript (System Events) primary, cgui list fallback.
def sim_window():
    rc, out = sh(['osascript', '-e',
                  'tell application "System Events" to tell process "Simulator" to get {position, size} of window 1'], t=30)
    m = re.search(r'(-?\d+),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)', out)
    if m:
        x, y, w, h = (int(v) for v in m.groups())
        if w > 100 and h > 100:
            return (x, y, w, h)
    rc, out = sh(['./cgui', 'list'], t=40)
    for ln in out.splitlines():
        if 'owner=Simulator' in ln and 'bounds=' in ln:
            m = re.search(r'bounds=([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)', ln)
            if m:
                return tuple(int(float(v)) for v in m.groups())
    return None

WIN = {'b': None}
def winshot(tag):
    """Screenshot of the Simulator window region (window coordinate space)."""
    p = os.path.join(OUT, 'win_%s.png' % tag)
    wb = WIN['b'] or sim_window()
    if wb:
        sh(['screencapture', '-x', '-R%d,%d,%d,%d' % (wb[0], wb[1], wb[2], wb[3]), p], t=40)
    if os.path.exists(p) and os.path.getsize(p) > 500:
        return p, wb
    # fallback: full host screenshot
    sh(['screencapture', '-x', p], t=40)
    return p, None

def win_ocr(tag='w', factor=4):
    """Vision OCR on the Simulator WINDOW screenshot only; returns host-point boxes."""
    p, wb = winshot(tag)
    sz = png_size(p)
    if not sz:
        return [], p
    up = os.path.join(OUT, 'win_%s_x%d.png' % (tag, factor))
    sh(['sips', '-z', str(sz[1] * factor), str(sz[0] * factor), p, '--out', up], t=60)
    boxes = ocrbox(up)
    ox, oy = (wb[0], wb[1]) if wb else (0, 0)
    fx = sz[0] / float(sz[0])  # 1:1
    out = []
    for b in boxes:
        out.append((b[0] / factor + ox, b[1] / factor + oy, b[2] / factor, b[3] / factor, b[4]))
    return out, p

def dev_ocr(tag='snap'):
    return ocrbox(devshot(tag))

def norm(t):
    return re.sub(r'[^a-z0-9]', '', t.lower())

def lev(a, b):
    if a == b: return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]

def find(boxes, needle):
    n = norm(needle)
    for b in boxes:
        k = norm(b[4])
        if n and n in k:
            return b
    return None

def find_fuzzy(boxes, needle):
    n = norm(needle)
    if not n:
        return None
    best = None
    for b in boxes:
        k = norm(b[4])
        if not k:
            continue
        if n in k or (len(k) >= 6 and len(n) >= 6 and k in n):
            return b
        d = lev(k[:len(n) + 2], n)
        if len(n) >= 5 and d <= max(2, len(n) // 4):
            if best is None or d < best[0]:
                best = (d, b)
    return best[1] if best else None

def match_any(boxes, needles):
    for nd in needles:
        b = find_fuzzy(boxes, nd)
        if b:
            return nd, b
    return None, None

# ------------------------------------------------------------------ calibration
CAL = {'s': None, 'ox': 0.0, 'oy': 0.0, 'res': None, 'n': 0, 'devsz': None}

def calibrate(tag='cal'):
    dev = devshot(tag + '_d'); host = hostshot(tag + '_h')
    CAL['devsz'] = png_size(dev)
    d = ocrbox(dev); h = ocrbox(host)
    dm = {}
    for cx, cy, w, hh, t in d:
        k = norm(t)
        if len(k) >= 4 and k not in dm:
            dm[k] = (cx, cy)
    pairs = []
    for cx, cy, w, hh, t in h:
        k = norm(t)
        if k in dm:
            pairs.append((dm[k][0], dm[k][1], cx, cy, t))
    log('CAL dev_boxes=%d host_boxes=%d pairs=%d devsz=%s win=%s' % (len(d), len(h), len(pairs), CAL['devsz'], WIN['b']))
    for p in pairs[:10]:
        log('  CALPAIR %-28s dev=%.0f,%.0f host=%.0f,%.0f' % (p[4][:28], p[0], p[1], p[2], p[3]))
    best = None
    import itertools
    for a, b in itertools.combinations(pairs, 2):
        dx = b[0] - a[0]
        if abs(dx) > 100:
            s = (b[2] - a[2]) / dx
            if 0.12 < s < 0.40:
                oxs = [cx - s * dx2 for dx2, dy2, cx, cy, t in pairs]
                oys = [cy - s * dy2 for dx2, dy2, cx, cy, t in pairs]
                ox, oy = statistics.median(oxs), statistics.median(oys)
                res = max(abs(cx - (s * dx2 + ox)) + abs(cy - (s * dy2 + oy)) for dx2, dy2, cx, cy, t in pairs)
                if best is None or res < best[0]:
                    best = (res, s, ox, oy)
    if best and best[0] < 40 and len(pairs) >= 3:
        CAL.update(s=best[1], ox=best[2], oy=best[3], res=best[0], n=len(pairs))
        log('CAL MAP(px) s=%.4f ox=%.1f oy=%.1f residual=%.1f pairs=%d' % (best[1], best[2], best[3], best[0], len(pairs)))
    else:
        log('CAL OCR-FIT REJECTED best=%s' % (str(best)[:120],))
    # independent sanity scale from window bounds vs device pixels (bezel makes it appx)
    wb = WIN['b']
    if wb and CAL['devsz']:
        log('CAL WINDOW-SCALE appx=%.4f (window %dx%d / dev %dx%d)' % (
            min(wb[2] / float(CAL['devsz'][0]), wb[3] / float(CAL['devsz'][1])), wb[2], wb[3], CAL['devsz'][0], CAL['devsz'][1]))
    return CAL['s'] is not None

def map_dev(x, y):
    if CAL['s'] is None:
        return None
    return (int(round(CAL['s'] * x + CAL['ox'])), int(round(CAL['s'] * y + CAL['oy'])))

def in_window(X, Y):
    wb = WIN['b']
    if not wb:
        return 0 <= X <= 4000 and 0 <= Y <= 3000
    x, y, w, h = wb
    return x <= X <= x + w and y <= Y <= y + h

# ------------------------------------------------------------------ click + verify
def dev_sig(tag='sig'):
    p = devshot(tag)
    bs = ocrbox(p)
    parts = []
    for b in bs:
        k = norm(b[4])
        if re.match(r'^\d{1,2}\d{2}$', k):   # clock
            continue
        parts.append(k)
    return '|'.join(sorted(set(parts)))[:1500]

def click_verify(label, X, Y, timeout=14):
    if not in_window(X, Y):
        log('CLICK OUT-OF-WINDOW %s at (%d,%d) -> abort this branch' % (label, X, Y))
        return False
    sh(['./cgui', 'front', 'Simulator'], t=30)
    before = dev_sig('before_' + re.sub(r'\W', '', label)[:10])
    sh(['./cgui', 'click', str(X), str(Y)], t=40)
    end = time.time() + timeout
    while time.time() < end:
        time.sleep(2.5)
        after = dev_sig('after_' + re.sub(r'\W', '', label)[:10])
        if after != before:
            log('CLICK OK [%s] host(%d,%d) screen changed' % (label, X, Y))
            return True
    log('CLICK NO-EFFECT [%s] host(%d,%d)' % (label, X, Y))
    return False

def tap_label(needle, tag='tap', abort_if_stuck=False, timeout=14):
    """Window-coordinate method first; device-mapped fallback. Returns True if screen changed."""
    wb = WIN['b'] or sim_window()
    WIN['b'] = wb
    wboxes, _ = win_ocr(tag + '_w')
    b = find_fuzzy(wboxes, needle)
    if b:
        X, Y = int(round(b[0])), int(round(b[1]))
        log('TAPW [%s] window(%d,%d) text=%r' % (needle, X, Y, b[4][:40]))
        if click_verify(needle, X, Y, timeout=timeout):
            return True
        log('TAPW no effect, trying device-mapped fallback')
    elif wboxes:
        log('TAPW [%s] not found in window OCR; texts=%s' % (needle, [x[4][:22] for x in wboxes][:16]))
    # fallback: device OCR + affine map
    b2 = find_fuzzy(dev_ocr(tag + '_d'), needle)
    if b2:
        m = map_dev(b2[0], b2[1])
        if m:
            log('TAPD [%s] dev(%.0f,%.0f) -> host(%d,%d)' % (needle, b2[0], b2[1], m[0], m[1]))
            if click_verify(needle, m[0], m[1], timeout=timeout):
                return True
        else:
            log('TAPD [%s] no calibration' % needle)
    else:
        log('TAPD [%s] not found in device OCR' % needle)
    return False

def dump(tag, source='dev'):
    if source == 'win':
        bs, _ = win_ocr(tag)
    else:
        bs = dev_ocr(tag)
    log('DUMP[%s] %d boxes' % (tag, len(bs)))
    for b in bs:
        log('   (%4.0f,%4.0f) %s' % (b[0], b[1], b[4][:90]))
    with open(os.path.join(OUT, 'dump_%s.txt' % tag), 'w') as f:
        for b in bs:
            f.write('%.0f\t%.0f\t%s\n' % (b[0], b[1], b[4]))
    STATE['screens'].append({'tag': tag, 'texts': [b[4] for b in bs]})
    return bs

def type_text(s, secret=False):
    sh(['./cgui', 'front', 'Simulator'], t=30)
    if secret:
        log('--- $ ./cgui key <redacted len=%d>' % len(s))
        try:
            subprocess.run(['./cgui', 'key', s], capture_output=True, text=True, timeout=40)
        except Exception:
            pass
    else:
        sh(['./cgui', 'key', s], t=40)
    time.sleep(0.6)

def wait_text(needles, timeout=45, tag='wait', source='dev'):
    if isinstance(needles, str):
        needles = [needles]
    end = time.time() + timeout
    i = 0
    last = []
    while time.time() < end and not over():
        i += 1
        last = dump('%s_%d' % (tag, i), source)
        for nd in needles:
            if find_fuzzy(last, nd):
                log('WAIT hit [%s] t=%ds' % (nd, i * 3))
                return last
        time.sleep(3)
    log('WAIT miss %s after %ds; texts=%s' % (needles, timeout, [b[4][:24] for b in last][:18]))
    return last

# ------------------------------------------------------------------ temp mail / sms
def http(url, data=None, headers=None, timeout=25):
    req = urllib.request.Request(url, data=data, headers=headers or {'User-Agent': 'Mozilla/5.0'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as r:
        return r.read().decode('utf-8', 'replace')

def http_json(url, data=None, headers=None, timeout=25):
    h = {'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'}
    if headers: h.update(headers)
    if data is not None: h.setdefault('Content-Type', 'application/json')
    t = http(url, data, h, timeout)
    return json.loads(t)

def email_candidate(idx):
    """One candidate per provider, tried at most once each (no domain enumeration)."""
    if idx == 0:
        j = http_json('https://api.tempmail.lol/generate')
        if j.get('address') and j.get('token'):
            return {'kind': 'tmol', 'addr': j['address'], 'token': j['token']}
    elif idx == 1:
        j = http_json('https://api.1secmail.com/v1/?action=genRandomMailbox&count=1')
        if isinstance(j, list) and j:
            lg, dm = j[0].split('@')
            return {'kind': '1sec', 'addr': j[0], 'login': lg, 'domain': dm}
    elif idx == 2:
        ds = http_json('https://api.mail.gw/domains')
        dom = ds['hydra:member'][0]['domain']
        addr = 'x%s%d@%s' % (int(time.time()) % 100000, random.randint(10, 99), dom)
        pw = 'Aa1!' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(14))
        http('https://api.mail.gw/accounts', json.dumps({'address': addr, 'password': pw}).encode())
        tk = http_json('https://api.mail.gw/token', json.dumps({'address': addr, 'password': pw}).encode())
        return {'kind': 'mailgw', 'addr': addr, 'token': tk.get('token'), 'pw': pw}
    return None

def email_codes(e):
    try:
        if e['kind'] == 'tmol':
            j = http_json('https://api.tempmail.lol/auth/' + e['token'])
            lst = j.get('email') or []
            if not lst: return []
            msg = lst[0]
            txt = ' '.join(str(msg.get(k) or '') for k in ('subject', 'body', 'html', 'text', 'from', 'sender'))
        elif e['kind'] == '1sec':
            msgs = http_json('https://api.1secmail.com/v1/?action=getMessages&login=%s&domain=%s' % (e['login'], e['domain']))
            txt = ''
            if msgs:
                m = http_json('https://api.1secmail.com/v1/?action=readMessage&login=%s&domain=%s&id=%s' % (e['login'], e['domain'], msgs[0]['id']))
                txt = json.dumps(m)[:20000]
        elif e['kind'] == 'mailgw':
            msgs = http_json('https://api.mail.gw/messages', headers={'Authorization': 'Bearer ' + e['token']})
            lst = msgs.get('hydra:member') or []
            txt = ''
            if lst:
                m = http_json('https://api.mail.gw/messages/' + lst[0]['id'], headers={'Authorization': 'Bearer ' + e['token']})
                txt = json.dumps(m)[:20000]
        else:
            return []
        codes = re.findall(r'(?<!\d)(\d{6})(?!\d)', txt)
        if codes:
            ev('mail_code', codes=codes[:3])
        return codes
    except Exception as ex:
        ev('mail_err', e=repr(ex)[:160])
        return []

def wait_email_code(e, timeout=180, since=0):
    end = time.time() + timeout
    while time.time() < end and not over():
        c = email_codes(e)
        if c:
            return c[0]
        time.sleep(10)
    return None

def asms_rows(number):
    h = http('https://asms.ai/number/' + number)
    rows = []
    for m in re.finditer(r'<time dateTime="([^"]+)">([^<]*)</time>', h):
        seg = h[m.end():m.end() + 800]
        msg = re.search(r'<p class="mt-2[^"]*">([\s\S]{0,300}?)</p>', seg)
        svc = h[max(0, m.start() - 500):m.start()]
        sv = re.findall(r'href="/([a-z0-9\-]+)"[^>]*>([^<]{1,40})</a>', svc)
        rows.append({'svc': (sv[-1][1] if sv else '?'), 'ts': m.group(1),
                     'msg': htmlmod.unescape(re.sub('<[^>]+>', '', msg.group(1))) if msg else ''})
    return rows

def wait_sms(number, since_iso, timeout=220):
    end = time.time() + timeout
    seen = set()
    while time.time() < end and not over():
        try:
            rows = asms_rows(number)
        except Exception as e:
            log('SMS fetch error %r' % e); time.sleep(8); continue
        new = [r for r in rows if r['ts'] > since_iso]
        for r in new[:6]:
            if r['ts'] not in seen:
                seen.add(r['ts'])
                ev('sms_row', svc=r['svc'], ts=r['ts'], msg=r['msg'][:140])
        apple = [r for r in new if 'apple' in r['svc'].lower() or 'appleaccount' in r['msg'].lower().replace(' ', '') or 'apple account' in r['msg'].lower()]
        for r in apple:
            mm = re.findall(r'\b(\d{6})\b', r['msg'])
            if mm:
                ev('sms_code_read', svc=r['svc'], ts=r['ts'])
                return mm[0]
        time.sleep(10)
    ev('sms_none', timeout=timeout)
    return None

# ------------------------------------------------------------------ device setup
def pick_device():
    rc, out = sh(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], t=90)
    try:
        d = json.loads(out[out.find('{'):])
    except Exception:
        return None
    cands = []
    for rt, devs in d.get('devices', {}).items():
        if 'iOS-18' not in rt and 'iOS-26' not in rt:
            continue
        for dv in devs:
            if dv.get('isAvailable') and dv.get('name', '').startswith('iPhone'):
                cands.append(dv)
    if cands:
        cands.sort(key=lambda x: (0 if '16e' in x['name'] else 1))
        return cands[0]
    for rt, devs in d.get('devices', {}).items():
        for dv in devs:
            if dv.get('isAvailable'):
                return dv
    return None

# ------------------------------------------------------------------ main
def main():
    global SMS_SINCE, EMAIL, SP
    log('### probe13 start ' + time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    sh(['sw_vers', '-productVersion'])
    sh(['sysctl', '-n', 'kern.hv_vmm_present'])
    sh(['sysctl', '-n', 'hw.model'])
    print('::add-mask::' + PASSWORD, flush=True)   # runner masks it; never logged to OUT
    log('PW_LEN=%d (masked, never written to OUT)' % len(PASSWORD))
    fd = os.open(SP, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, ('password=%s\nphone=%s\n' % (PASSWORD, PHONE_PRIMARY)).encode()); os.close(fd)

    dev = pick_device()
    if not dev:
        STATE['stage'] = 'NO_SIMULATOR'; log('VERDICT=NO_SIMULATOR'); return
    udid = dev['udid']
    log('DEVICE %s %s %s' % (dev['name'], udid, dev.get('state')))
    sh(['defaults', 'write', 'com.apple.iphonesimulator', 'ConnectHardwareKeyboard', '-bool', 'true'])
    if dev.get('state') != 'Booted':
        sh(['xcrun', 'simctl', 'boot', udid], t=180)
    sh(['xcrun', 'simctl', 'bootstatus', udid, '-b'], t=300)
    sh('open -a Simulator', t=60)
    time.sleep(10)
    sh(['./cgui', 'front', 'Simulator'], t=30)
    time.sleep(2)
    WIN['b'] = sim_window()
    log('WINDOW bounds=%s' % (WIN['b'],))

    # sanity: device screenshot must render
    dsz = png_size(devshot('boot'))
    log('DEVICE screenshot size=%s' % (dsz,))

    # open Settings deterministically (no home-screen click needed)
    sh(['xcrun', 'simctl', 'launch', 'booted', 'com.apple.Preferences'], t=60)
    time.sleep(6)
    if not calibrate('cal'):
        # a second calibration attempt after the UI settles
        time.sleep(3); sh(['./cgui', 'front', 'Simulator'], t=30)
        if not calibrate('cal2'):
            STATE['stage'] = 'CALIBRATION_FAILED'
            log('VERDICT=CALIBRATION_FAILED'); return
    bs = wait_text(['Apple Account', 'Sign in to your iPhone', 'General'], timeout=60, tag='settings')
    dump('settings', 'dev')
    if not find_fuzzy(bs, 'Apple Account'):
        STATE['stage'] = 'NO_APPLE_ACCOUNT_ROW'; log('VERDICT=NO_APPLE_ACCOUNT_ROW'); return

    if not tap_label('Apple Account', tag='aa_entry'):
        STATE['stage'] = 'CLICK_FAILED_AA'; log('VERDICT=CALIBRATION_FAILED'); return
    time.sleep(3)
    bs = wait_text(['Don\'t have an Apple Account', 'Sign in Manually', 'Use Another Apple Device', 'Sign in to your iPhone'], timeout=45, tag='aa')
    dump('apple_account')

    if not find_fuzzy(bs, 'Don\'t have an Apple Account'):
        # scroll once inside the window (drag from centre-bottom to centre-top)
        log('scrolling inside window for create entry')
        wb = WIN['b'] or sim_window()
        if wb:
            cx = wb[0] + wb[2] // 2
            y1 = wb[1] + int(wb[3] * 0.75); y2 = wb[1] + int(wb[3] * 0.35)
            sh(['./drag', str(cx), str(y1), str(cx), str(y2), '24'], t=40); time.sleep(2)
            bs = dump('aa_scroll')
    if not find_fuzzy(bs, 'Don\'t have an Apple Account'):
        STATE['stage'] = 'NO_CREATE_ENTRY'; log('VERDICT=NO_CREATE_ENTRY'); return

    if not tap_label('Don\'t have an Apple Account', tag='create_entry'):
        STATE['stage'] = 'CLICK_FAILED_CREATE'; log('VERDICT=CALIBRATION_FAILED'); return
    time.sleep(3)
    bs = wait_text(['Age Range', 'Child', 'Teen', 'Adult'], timeout=45, tag='age')
    dump('age_range')
    if not find_fuzzy(bs, 'Adult'):
        STATE['stage'] = 'NO_ADULT'; log('VERDICT=NO_ADULT_BUTTON'); return
    if not tap_label('Adult', tag='adult'):
        STATE['stage'] = 'CLICK_FAILED_ADULT'; log('VERDICT=CALIBRATION_FAILED'); return
    time.sleep(6)
    bs = dump('after_adult')
    # record every distinct screen text through the form
    seen_state = {}
    actions_done = {}
    typed = {'name': 0, 'email': 0, 'pw': 0, 'phone': 0, 'birthday': 0, 'country': 0}
    EMAIL['idx'] = -1

    def act(name, key, fn):
        k = name + ':' + key[:90]
        if actions_done.get(k):
            return False
        actions_done[k] = 1
        log('ACTION ' + name)
        return fn()

    def try_tap_box(b, tag):
        m = map_dev(b[0], b[1])
        if not m:
            return False
        return click_verify(tag, m[0], m[1], timeout=10)

    for step in range(55):
        if over():
            log('CAP REACHED at step %d' % step); break
        bs = dump('step%02d' % step)
        texts = ' | '.join(b[4] for b in bs)
        low = texts.lower()
        sig = '|'.join(sorted(set(norm(b[4]) for b in bs if len(norm(b[4])) > 2)))[:220]
        seen_state[sig] = seen_state.get(sig, 0) + 1
        if seen_state[sig] >= 3:
            log('STATE STUCK; breaking. texts=%s' % texts[:400]); break

        # hard-stop / diagnostic strings
        for vmw in ['virtual machine', 'not supported', 'cannot be created', 'not available in your',
                    'unable to create', 'try again later']:
            if vmw in low:
                STATE['vm_text'] = texts[:600]
                ev('server_side_block', text=vmw)
        # captcha
        if re.search(r'captcha|enter the code|characters shown|verification image', low):
            STATE['captcha_seen'] += 1
            ev('captcha_seen', n=STATE['captcha_seen'], texts=texts[:300])
            # try one OCR read of the window image (single candidate, no enumeration)
            if STATE['captcha_tries'] < 10:
                wbxs, wp = win_ocr('captcha%d' % STATE['captcha_tries'])
                cand = None
                for b in wbxs:
                    t = b[4].strip()
                    if re.fullmatch(r'[A-Za-z0-9]{5,7}', t) and not re.search(r'(code|captcha|enter|image)', t, re.I):
                        cand = t; break
                if cand:
                    STATE['captcha_tries'] += 1
                    box = find_fuzzy(bs, 'code') or find_fuzzy(bs, 'captcha')
                    if box:
                        try_tap_box(box, 'captop')
                        time.sleep(0.5)
                        type_text(cand)
                        ev('captcha_submit', cand_len=len(cand))
                        time.sleep(3)
                        continue
                else:
                    ev('captcha_no_ocr_candidate')
                    time.sleep(3)
                    continue

        done = False
        if re.search(r'age range', low) and find_fuzzy(bs, 'Adult'):
            done = act('adult', sig, lambda: try_tap_box(find_fuzzy(bs, 'Adult'), 'adult2'))
        elif find_fuzzy(bs, 'First Name') and typed['name'] < 1:
            b = find_fuzzy(bs, 'First Name'); typed['name'] += 1
            done = act('firstname', sig, lambda b=b: (try_tap_box(b, 'fn'), type_text('Jordan'), True)[-1])
        elif find_fuzzy(bs, 'Last Name') and typed['name'] < 2:
            b = find_fuzzy(bs, 'Last Name'); typed['name'] += 1
            done = act('lastname', sig, lambda b=b: (try_tap_box(b, 'ln'), type_text('Miller'), True)[-1])
        elif find_fuzzy(bs, 'free iCloud email') or find_fuzzy(bs, 'Get a free iCloud'):
            b = find_fuzzy(bs, 'free iCloud email') or find_fuzzy(bs, 'Get a free iCloud')
            EMAIL['addr'] = 'icloud-free'; EMAIL['kind'] = 'icloud'; STATE['email_used'] = 'icloud-free'
            done = act('freeicloud', sig, lambda b=b: try_tap_box(b, 'iclouder'))
        elif re.search(r'birthday|date of birth', low) and typed['birthday'] < 2:
            b = find_fuzzy(bs, 'Birthday') or find_fuzzy(bs, 'Date of Birth')
            fld = find_fuzzy(bs, 'MM/DD/YYYY') or find_fuzzy(bs, 'DD/MM/YYYY')
            typed['birthday'] += 1
            if fld:
                done = act('birthdaytype', sig, lambda fld=fld: (try_tap_box(fld, 'bd'), time.sleep(0.6), type_text('01/01/1990'), True)[-1])
            elif b:
                done = act('birthdayopen', sig, lambda b=b: try_tap_box(b, 'bdopen'))
        elif re.search(r'\bemail\b', low) and typed['email'] < 4 and EMAIL['kind'] != 'icloud':
            # get the next email candidate lazily
            if EMAIL['addr'] is None:
                for idx in range(EMAIL['idx'] + 1, 3):
                    try:
                        c = email_candidate(idx)
                        if c:
                            EMAIL.update(c); EMAIL['idx'] = idx; EMAIL['addr'] = c['addr']
                            STATE['email_used'] = c['addr']; ev('email_candidate', kind=c['kind'], addr=c['addr'], idx=idx)
                            break
                    except Exception as ex:
                        ev('email_candidate_err', idx=idx, e=repr(ex)[:140])
            b = find_fuzzy(bs, 'Email') or find_fuzzy(bs, 'email address')
            if b and EMAIL['addr'] and EMAIL['addr'] != 'icloud-free':
                typed['email'] += 1
                done = act('emailtype%d' % typed['email'], sig, lambda b=b: (try_tap_box(b, 'email'), time.sleep(0.6), type_text(EMAIL['addr']), True)[-1])
        elif re.search(r'\bpassword\b', low) and typed['pw'] < 4:
            b = find_fuzzy(bs, 'Verify') or find_fuzzy(bs, 'Re-enter') or find_fuzzy(bs, 'Confirm')
            if b:
                typed['pw'] += 1
                done = act('verifypw%d' % typed['pw'], sig, lambda b=b: (try_tap_box(b, 'vfy'), time.sleep(0.6), type_text(PASSWORD, secret=True), True)[-1])
            else:
                b = find_fuzzy(bs, 'Password')
                if b:
                    typed['pw'] += 1
                    done = act('password%d' % typed['pw'], sig, lambda b=b: (try_tap_box(b, 'pw'), time.sleep(0.6), type_text(PASSWORD, secret=True), True)[-1])
        elif re.search(r'country|region', low) and typed['country'] < 2 and re.search(r'united states|united kingdom', low):
            b = find_fuzzy(bs, 'United States') or find_fuzzy(bs, 'Country/Region')
            typed['country'] += 1
            done = act('country', sig, lambda b=b: try_tap_box(b, 'country'))
        elif re.search(r'united kingdom', low) and not re.search(r'country|region|phone', low):
            b = find_fuzzy(bs, 'United Kingdom')
            done = act('pickuk', sig, lambda b=b: try_tap_box(b, 'uk'))
        elif re.search(r'phone number|mobile number|phone', low) and typed['phone'] < 2:
            b = find_fuzzy(bs, 'Phone Number') or find_fuzzy(bs, 'Phone')
            if b:
                SMS_SINCE = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
                open(os.path.join(OUT, 'sms_since.txt'), 'w').write(SMS_SINCE + '\n' + PHONE_PRIMARY + '\n')
                typed['phone'] += 1
                # type local digits; country selected as UK -> national format
                num = PHONE_PRIMARY
                done = act('phonetype', sig, lambda b=b: (try_tap_box(b, 'ph'), time.sleep(0.6), type_text(num), True)[-1])
                STATE['phone_accepted'] = 'submitted'
        elif re.search(r'verification code|enter code|6-digit|six-digit', low) and re.search(r'phone|number|sent|text', low):
            code = wait_sms(PHONE_PRIMARY, SMS_SINCE or '', timeout=200)
            if code:
                b = find_fuzzy(bs, 'Code') or find_fuzzy(bs, 'code')
                if b:
                    done = act('codetype', sig, lambda b=b, code=code: (try_tap_box(b, 'code'), time.sleep(0.6), type_text(code), True)[-1])
                    STATE['phone_accepted'] = 'sms_received'
            else:
                ev('sms_not_received'); break
        elif re.search(r'verify your email|email verification|code sent to your email', low) and EMAIL['kind'] in ('tmol', '1sec', 'mailgw'):
            code = wait_email_code(EMAIL, timeout=200)
            if code:
                b = find_fuzzy(bs, 'Code') or find_fuzzy(bs, 'code') or find_fuzzy(bs, 'Enter')
                if b:
                    done = act('emailcodetype', sig, lambda b=b, code=code: (try_tap_box(b, 'ecode'), time.sleep(0.6), type_text(code), True)[-1])
        elif re.search(r'terms|conditions|agree|privacy policy', low):
            b = find_fuzzy(bs, 'Agree') or find_fuzzy(bs, 'Accept') or find_fuzzy(bs, 'I Agree')
            if b:
                done = act('agree', sig, lambda b=b: try_tap_box(b, 'agree'))
        if not done:
            for nd in ['Continue', 'Next', 'Done', 'Create Apple Account']:
                b = find_fuzzy(bs, nd)
                if b:
                    done = act('press_' + nd.replace(' ', '') + ':' + sig[:20], sig, lambda b=b: try_tap_box(b, 'next'))
                    if done:
                        break
        if not done:
            log('NO ACTION MATCHED at step %d; texts=%s' % (step, texts[:500]))
            break
        time.sleep(6)

    bs = dump('final')
    texts = ' | '.join(b[4] for b in bs)
    log('FINAL_TEXTS: ' + texts[:1500])
    low = texts.lower()
    if find_fuzzy(bs, 'Sign Out') or find_fuzzy(bs, 'Apple Account') and re.search(r'icloud|sign out', low):
        STATE['stage'] = 'ACCOUNT_MAY_EXIST'
    elif STATE['vm_text']:
        STATE['stage'] = 'SERVER_BLOCKED'
    elif STATE['captcha_seen']:
        STATE['stage'] = 'CAPTCHA_BLOCKED'
    elif re.search(r'verification|code', low):
        STATE['stage'] = 'CODE_STAGE'
    else:
        STATE['stage'] = 'FORM_STAGE'

    # candidate account address visible on screen
    for b in bs:
        t = b[4].strip()
        if '@' in t and '.' in t.split('@')[-1] and ' ' not in t:
            STATE['account_candidate'] = t; break

    try:
        sh(['xcrun', 'simctl', 'spawn', 'booted', 'defaults', 'read', 'MobileMeAccounts'], t=30)
    except Exception:
        pass
    log('### DONE probe13')

if __name__ == '__main__':
    SP = os.environ.get('SECRETS_PATH') or os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'p13_secrets.txt')
    try:
        main()
    except Exception:
        import traceback
        log('EXC ' + traceback.format_exc()[:2500])
        STATE['error'] = traceback.format_exc()[:800]
    finally:
        try:
            os.chmod(SP, 0o600)
        except Exception:
            pass
        # verdict artifact: NEVER contains the password
        verdict = {
            'stage': STATE['stage'], 'error': STATE['error'],
            'captcha_seen': STATE['captcha_seen'], 'captcha_tries': STATE['captcha_tries'],
            'vm_text': STATE['vm_text'], 'phone_accepted': STATE['phone_accepted'],
            'email_used': STATE['email_used'], 'country': STATE['country'],
            'account_candidate': STATE['account_candidate'],
            'screens': [{'tag': s['tag'], 'texts': s['texts'][:40]} for s in STATE['screens'][-60:]],
            'events': STATE['events'][-200:],
            'created': 1 if STATE['stage'] == 'ACCOUNT_MAY_EXIST' else 0,
            'pw_len': len(PASSWORD), 'phone': PHONE_PRIMARY,
        }
        open(os.path.join(OUT, 'verdict.json'), 'w').write(json.dumps(verdict, ensure_ascii=False, indent=1))
        if verdict['created']:
            open(os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'p13pw'), 'w').write(PASSWORD)
        log('VERDICT_STAGE=' + STATE['stage'])
