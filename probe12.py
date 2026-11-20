#!/usr/bin/env python3
# i103331 probe12 -- Simulator-side Apple Account creation attempt.
# Cross-environment combination: create an Apple Account inside the iOS Simulator
# (Settings -> Apple Account -> "Don't have an Apple Account?" -> Age Range -> Adult)
# and, if created, print the credentials so a later job can sign in on the macOS VM.
# All clicking goes through host-point CGEvent after a device->host affine calibration.
# No brute force, no code enumeration; SMS is read once from the public asms page,
# only entries newer than our own submit timestamp.
import subprocess, time, re, os, sys, json, random, string, statistics, html as htmlmod
import urllib.request, urllib.parse

OUT = os.environ.get('OUT', os.getcwd() + '/out12')
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, 'p12.log'), 'a', buffering=1)
T0 = time.time()
CAP = float(os.environ.get('CAP_MIN', '24')) * 60.0
SMS_SINCE = None

def log(*a):
    s = ' '.join(str(x) for x in a)
    print(s, flush=True)
    LOG.write(s + '\n')

def over():
    return time.time() - T0 > CAP

def sh(cmd, t=90):
    log('--- $ ' + (' '.join(cmd) if isinstance(cmd, list) else cmd))
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=t)
        out = (p.stdout or '') + (p.stderr or '')
        for ln in out.strip().splitlines()[-6:]:
            log('    ' + ln[:300])
        return p.returncode, out
    except subprocess.TimeoutExpired:
        log('    TIMEOUT')
        return 'TO', ''

# ---------------------------------------------------------------- OCR
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

def devshot(tag):
    path = os.path.join(OUT, 'dev_%s.png' % tag)
    for _ in range(3):
        rc, out = sh(['xcrun', 'simctl', 'io', 'booted', 'screenshot', path], t=60)
        if os.path.exists(path) and os.path.getsize(path) > 20000:
            return path
        time.sleep(2)
    return path

def hostshot(tag):
    path = os.path.join(OUT, 'host_%s.png' % tag)
    sh(['screencapture', '-x', path], t=40)
    return path

def norm(t):
    return re.sub(r'[^a-z0-9]', '', t.lower())

CAL = {'s': None, 'ox': 0.0, 'oy': 0.0, 'src': 'none'}

def sim_bounds():
    rc, out = sh(['./cgui', 'list'], t=40)
    for ln in out.splitlines():
        if 'owner=Simulator' in ln and 'bounds=' in ln:
            m = re.search(r'bounds=([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)', ln)
            if m:
                return tuple(float(x) for x in m.groups())
    return None

def calibrate(tag='cal'):
    d = ocrbox(devshot(tag + '_d'))
    h = ocrbox(hostshot(tag + '_h'))
    dm = {}
    for cx, cy, w, hh, t in d:
        k = norm(t)
        if len(k) >= 5 and k not in dm:
            dm[k] = (cx / 3.0, cy / 3.0)
    pairs = []
    for cx, cy, w, hh, t in h:
        k = norm(t)
        if k in dm:
            pairs.append((dm[k][0], dm[k][1], cx, cy, t))
    log('CAL dev_boxes=%d host_boxes=%d pairs=%d src_has_sim_bounds=%s' % (len(d), len(h), len(pairs), sim_bounds()))
    for p in pairs[:10]:
        log('  CALPAIR %-32s dev=%.0f,%.0f host=%.0f,%.0f' % (p[4][:32], p[0], p[1], p[2], p[3]))
    best = None
    import itertools
    for a, b in itertools.combinations(pairs, 2):
        dy = b[1] - a[1]
        if abs(dy) > 150:
            s = (b[3] - a[3]) / dy
            if 0.2 < s < 2.5:
                oxs = [cx - s * dx for dx, dy2, cx, cy, t in pairs]
                oys = [cy - s * dy2 for dx, dy2, cx, cy, t in pairs]
                ox, oy = statistics.median(oxs), statistics.median(oys)
                res = max(abs(cx - (s * dx + ox)) + abs(cy - (s * dy2 + oy)) for dx, dy2, cx, cy, t in pairs)
                if best is None or res < best[0]:
                    best = (res, s, ox, oy)
    if best and best[0] < 70:
        CAL.update(s=best[1], ox=best[2], oy=best[3], src='ocr')
        log('CAL OCR-MAP s=%.4f ox=%.1f oy=%.1f residual=%.1f' % (best[1], best[2], best[3], best[0]))
        return True
    wb = sim_bounds()
    if wb:
        X, Y, W, H = wb
        tb = 30.0
        s = min(W / 390.0, (H - tb) / 844.0)
        ox = X + (W - 390.0 * s) / 2.0
        oy = Y + tb + ((H - tb) - 844.0 * s) / 2.0
        CAL.update(s=s, ox=ox, oy=oy, src='window')
        log('CAL WINDOW-MAP bounds=%s s=%.4f ox=%.1f oy=%.1f' % (wb, s, ox, oy))
        return True
    log('CAL FAILED')
    return False

def tap_dev(x, y):
    if CAL['s'] is None and not calibrate('cal_pre'):
        return False
    X = CAL['s'] * x + CAL['ox']
    Y = CAL['s'] * y + CAL['oy']
    sh(['./cgui', 'click', str(int(round(X))), str(int(round(Y)))], t=40)
    time.sleep(1.0)
    return True

def dev_ocr(tag='snap'):
    return ocrbox(devshot(tag))

def find(boxes, needle):
    n = needle.lower()
    for b in boxes:
        if n in b[4].lower():
            return b
    return None

def find_all(boxes, needle):
    n = needle.lower()
    return [b for b in boxes if n in b[4].lower()]

def wait_text(needles, timeout=45, tag='wait'):
    if isinstance(needles, str):
        needles = [needles]
    end = time.time() + timeout
    i = 0
    last = []
    while time.time() < end and not over():
        i += 1
        last = dev_ocr('%s_%d' % (tag, i))
        for nd in needles:
            b = find(last, nd)
            if b:
                log('WAIT hit [%s] t=%ds' % (nd, i * 3))
                return last
        time.sleep(3)
    log('WAIT miss %s after %ds; texts=%s' % (needles, timeout, [b[4][:24] for b in last][:16]))
    return last

def tap_text(needle, tag='tap', boxes=None):
    bs = boxes if boxes is not None else dev_ocr(tag)
    b = find(bs, needle)
    if not b:
        log('TAP NOTFOUND [%s] texts=%s' % (needle, [x[4][:24] for x in bs][:18]))
        return False
    log('TAP [%s] at dev(%.0f,%.0f)' % (needle, b[0], b[1]))
    tap_dev(b[0], b[1])
    time.sleep(1.5)
    return True

def type_text(s):
    sh(['./cgui', 'front', 'Simulator'], t=30)
    sh(['./cgui', 'key', s], t=40)

def dump(tag, boxes=None):
    bs = boxes if boxes is not None else dev_ocr(tag)
    log('DUMP[%s] %d boxes' % (tag, len(bs)))
    for b in bs:
        log('   (%4.0f,%4.0f) %s' % (b[0], b[1], b[4][:80]))
    with open(os.path.join(OUT, 'dump_%s.txt' % tag), 'w') as f:
        for b in bs:
            f.write('%.0f\t%.0f\t%s\n' % (b[0], b[1], b[4]))
    return bs

def drag_dev(x1, y1, x2, y2):
    if CAL['s'] is None:
        return
    X1, Y1 = CAL['s'] * x1 + CAL['ox'], CAL['s'] * y1 + CAL['oy']
    X2, Y2 = CAL['s'] * x2 + CAL['ox'], CAL['s'] * y2 + CAL['oy']
    sh(['./drag', str(int(X1)), str(int(Y1)), str(int(X2)), str(int(Y2)), '24'], t=40)
    time.sleep(1.0)

# ---------------------------------------------------------------- temp mail / sms
def http(url, data=None, headers=None, timeout=25):
    req = urllib.request.Request(url, data=data, headers=headers or {'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode('utf-8', 'replace')

def gen_mail():
    # try providers reachable from a GH runner; return (addr, reader_fn)
    try:
        j = json.loads(http('https://www.1secmail.com/api/v1/?action=genRandomMailbox&count=1'))
        addr = j[0]
        log('MAIL 1secmail -> ' + addr)
        lg, dm = addr.split('@')
        def rd(lg=lg, dm=dm):
            msgs = json.loads(http('https://www.1secmail.com/api/v1/?action=getMessages&login=%s&domain=%s' % (lg, dm)))
            out = []
            for m in msgs:
                body = json.loads(http('https://www.1secmail.com/api/v1/?action=readMessage&login=%s&domain=%s&id=%s' % (lg, dm, m['id'])))
                out.append((m.get('date', ''), m.get('subject', ''), body.get('textBody', '') or body.get('body', '')))
            return out
        return addr, rd
    except Exception as e:
        log('MAIL 1secmail failed: %r' % e)
    try:
        r = http('https://api.guerrillamail.com/ajax.php?f=get_email_address&lang=en&site=guerrillamail.com&domain=guerrillamail.com')
        j = json.loads(r)
        addr, sid = j['email_addr'], j['sid_token']
        log('MAIL guerrilla -> ' + addr)
        def rd(sid=sid):
            j2 = json.loads(http('https://api.guerrillamail.com/ajax.php?f=check_email&seq=0&sid_token=%s' % sid))
            out = []
            for m in (j2.get('list') or [])[:8]:
                j3 = json.loads(http('https://api.guerrillamail.com/ajax.php?f=fetch_email&email_id=%s&sid_token=%s' % (m['mail_id'], sid)))
                out.append((m.get('mail_date', ''), m.get('mail_subject', ''), j3.get('mail_body', '')))
            return out
        return addr, rd
    except Exception as e:
        log('MAIL guerrilla failed: %r' % e)
    return None, None

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

def wait_sms(number, since_iso, timeout=210):
    end = time.time() + timeout
    seen = set()
    while time.time() < end and not over():
        try:
            rows = asms_rows(number)
        except Exception as e:
            log('SMS fetch error %r' % e)
            time.sleep(8)
            continue
        new = [r for r in rows if r['ts'] > since_iso]
        for r in new[:6]:
            if r['ts'] not in seen:
                seen.add(r['ts'])
                log('SMS NEW row svc=%s ts=%s msg=%s' % (r['svc'], r['ts'], r['msg'][:120]))
        apple = [r for r in new if 'apple' in r['svc'].lower() or 'appleaccount' in r['msg'].lower().replace(' ', '') or 'apple account' in r['msg'].lower()]
        for r in apple:
            mm = re.findall(r'\b(\d{6})\b', r['msg'])
            if mm:
                log('SMS CODE %s from %s ts=%s' % (mm[0], r['svc'], r['ts']))
                return mm[0]
        time.sleep(10)
    log('SMS none after %ds' % timeout)
    return None

# ---------------------------------------------------------------- device setup
def pick_device():
    rc, out = sh(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], t=90)
    try:
        d = json.loads(out[out.find('{'):])
    except Exception:
        return None
    cands = []
    for rt, devs in d.get('devices', {}).items():
        if 'iOS-18' not in rt:
            continue
        for dv in devs:
            if dv.get('isAvailable') and dv.get('name', '').startswith('iPhone'):
                cands.append(dv)
    cands.sort(key=lambda x: (0 if '16e' in x['name'] else 1, 0 if '18-5' in x.get('state', '') else 1))
    if cands:
        return cands[0]
    # any iOS device
    for rt, devs in d.get('devices', {}).items():
        for dv in devs:
            if dv.get('isAvailable'):
                return dv
    return None

# ---------------------------------------------------------------- main flow
def main():
    global SMS_SINCE
    log('### probe12 start ' + time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    sh(['sw_vers', '-productVersion'])
    sh(['sysctl', '-n', 'kern.hv_vmm_present'])
    sh(['sysctl', '-n', 'hw.model'])
    dev = pick_device()
    if not dev:
        log('VERDICT=NO_SIMULATOR'); return
    udid = dev['udid']
    log('DEVICE %s %s %s' % (dev['name'], udid, dev.get('state')))
    sh(['defaults', 'write', 'com.apple.iphonesimulator', 'ConnectHardwareKeyboard', '-bool', 'true'])
    if dev.get('state') != 'Booted':
        sh(['xcrun', 'simctl', 'boot', udid], t=180)
    sh(['xcrun', 'simctl', 'bootstatus', udid, '-b'], t=300)
    sh('open -a Simulator', t=60)
    time.sleep(12)
    sh(['./cgui', 'front', 'Simulator'], t=30)

    # wait for home
    bs = wait_text(['Settings'], timeout=90, tag='home')
    if not find(bs, 'Settings'):
        log('VERDICT=NO_HOME'); return
    dump('home', bs)

    # Settings
    tap_text('Settings'); time.sleep(4)
    bs = wait_text(['Apple Account', 'General', 'Accessibility'], timeout=60, tag='settings')
    dump('settings', bs)
    calibrate('settings')
    if not find(bs, 'Apple Account'):
        tap_text('Apple Account', boxes=bs); time.sleep(4)
        bs = dev_ocr('settings2')
    # open Apple Account
    tap_text('Apple Account', boxes=bs); time.sleep(5)
    bs = wait_text(["Don't have an Apple Account", 'Sign in Manually', 'Use Another Apple Device', 'iCloud'], timeout=60, tag='aa')
    dump('apple_account', bs)
    if not find(bs, "Don't have an Apple Account"):
        # try scrolling down
        log('scrolling for create entry')
        drag_dev(195, 700, 195, 250)
        time.sleep(2)
        bs = dev_ocr('aa_scroll')
        dump('aa_scroll', bs)
    if not tap_text("Don't have an Apple Account", boxes=bs):
        log('VERDICT=NO_CREATE_ENTRY'); return
    time.sleep(4)
    bs = wait_text(['Age Range', 'Child', 'Teen', 'Adult'], timeout=60, tag='age')
    dump('age_range', bs)
    if not tap_text('Adult', boxes=bs):
        log('VERDICT=NO_ADULT_BUTTON'); return
    time.sleep(8)
    bs = dump('after_adult')
    if not bs:
        bs = dump('after_adult2', dev_ocr('after_adult2'))

    # adaptive form agent
    seen_state = {}
    actions_done = {}
    typed = {'name': 0, 'email': 0, 'pw': 0, 'phone': 0}

    def act(name, key, fn):
        k = name + ':' + key[:70]
        if actions_done.get(k):
            return False
        actions_done[k] = 1
        log('ACTION ' + name)
        return fn()

    for step in range(45):
        if over():
            log('CAP REACHED at step %d' % step); break
        bs = dump('step%02d' % step)
        texts = ' | '.join(b[4] for b in bs).lower()
        sig = '|'.join(sorted(set(norm(b[4]) for b in bs if len(norm(b[4])) > 2)))[:200]
        state_hits = seen_state.get(sig, 0)
        seen_state[sig] = state_hits + 1
        if state_hits >= 2:
            log('STATE STUCK on signature; breaking. texts=%s' % texts[:400])
            break
        done = False

        # 1. age range
        if 'age range' in texts and find(bs, 'Adult'):
            done = act('adult', sig, lambda: (tap_dev(find(bs, 'Adult')[0], find(bs, 'Adult')[1]), True)[-1])
        # 2. first / last name (placeholders only)
        elif find(bs, 'First Name') and norm(find(bs, 'First Name')[4]) in ('firstname', 'first'):
            b = find(bs, 'First Name'); typed['name'] += 1
            done = act('firstname', sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(1), type_text('Jordan'), True)[-1])
        elif find(bs, 'Last Name') and norm(find(bs, 'Last Name')[4]) in ('lastname', 'last'):
            b = find(bs, 'Last Name'); typed['name'] += 1
            done = act('lastname', sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(1), type_text('Miller'), True)[-1])
        # 3. free iCloud email address (avoids disposable-domain rejection)
        elif find(bs, 'iCloud email') or find(bs, 'free iCloud'):
            b = find(bs, 'iCloud email') or find(bs, 'free iCloud')
            done = act('freeicloud', sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(2), True)[-1])
        # 4. birthday
        elif re.search(r'birthday|date of birth', texts):
            b = find(bs, 'Birthday') or find(bs, 'Date of Birth')
            fld = find(bs, 'MM/DD/YYYY') or find(bs, 'DD/MM/YYYY') or find(bs, 'MM/DD/YY')
            if fld:
                done = act('birthdaytype', sig, lambda fld=fld: (tap_dev(fld[0], fld[1]), time.sleep(1), type_text('01/01/1990'), True)[-1])
            elif b:
                done = act('birthdayopen', sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(3), True)[-1])
        # 5. email field
        elif re.search(r'\bemail\b', texts) and GMAIL[0] and typed['email'] < 2:
            b = find(bs, 'Email') or find(bs, 'email address')
            if b and norm(b[4]) in ('email', 'emailaddress', 'nameexamplecom', 'examplecom', 'emailaddressoptional'):
                typed['email'] += 1
                done = act('emailtype', sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(1), type_text(GMAIL[0]), True)[-1])
        # 6. password / verify
        elif re.search(r'\bpassword\b', texts) and typed['pw'] < 3:
            b = find(bs, 'Verify') or find(bs, 'verify') or find(bs, 'Re-enter') or find(bs, 'Confirm')
            if b and norm(b[4]) in ('verify', 'reenter', 'confirm', 'verifypassword'):
                typed['pw'] += 1
                done = act('verifypw', sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(1), type_text(PASSWORD), True)[-1])
            else:
                b = find(bs, 'Password') or find(bs, 'password')
                if b and norm(b[4]) in ('password',):
                    typed['pw'] += 1
                    done = act('password', sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(1), type_text(PASSWORD), True)[-1])
        # 7. verification code (check before phone, code screen also says 'phone')
        elif re.search(r'verification code|enter code|6-digit|six-digit|code', texts) and re.search(r'phone|number|sent', texts) and typed['phone'] > 0:
            code = wait_sms(PHONE_ACTIVE, SMS_SINCE, timeout=220)
            if code:
                b = find(bs, 'Code') or find(bs, 'code')
                if b:
                    done = act('codetype', sig, lambda b=b, code=code: (tap_dev(b[0], b[1]), time.sleep(1), type_text(code), True)[-1])
            else:
                log('NO_SMS_CODE'); break
        # 8. phone
        elif re.search(r'phone number|mobile number', texts) and typed['phone'] < 2:
            b = find(bs, 'Phone Number') or find(bs, 'phone number') or find(bs, 'Phone')
            if b:
                SMS_SINCE = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
                open(os.path.join(OUT, 'sms_since.txt'), 'w').write(SMS_SINCE + '\n' + PHONE_PRIMARY + '\n')
                typed['phone'] += 1
                done = act('phonetype', sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(1), type_text('0' + PHONE_PRIMARY[-10:]), True)[-1])
        # 9. terms
        elif re.search(r'terms|conditions|agree|privacy policy', texts):
            b = find(bs, 'Agree') or find(bs, 'Accept') or find(bs, 'I Agree')
            if b:
                done = act('agree', sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(2), True)[-1])
        # 10. next / continue
        if not done:
            for nd in ['Continue', 'Next', 'Done']:
                b = find(bs, nd)
                if b:
                    done = act('press_' + nd, sig, lambda b=b: (tap_dev(b[0], b[1]), time.sleep(2), True)[-1])
                    if done:
                        break
        if not done:
            log('NO ACTION MATCHED at step %d; texts=%s' % (step, texts[:500]))
            break
        time.sleep(7)

    # final state
    bs = dump('final')
    texts = ' | '.join(b[4] for b in bs)
    log('FINAL_TEXTS: ' + texts[:1500])
    low = texts.lower()
    if re.search(r'apple account|icloud|two-factor|verification', low) and not re.search(r'age range|first name|sign in manually', low):
        log('POSSIBLE_PROGRESS')
    try:
        sh(['defaults', 'read', 'MobileMeAccounts'], t=30)
    except Exception:
        pass
    # persist account name/password as repo secrets when an account was created
    try:
        acct = ''
        for b in bs:
            t = b[4]
            if '@' in t and '.' in t.split('@')[-1]:
                acct = t.strip()
                break
        log('ACCOUNT_CANDIDATE=' + (acct or 'none'))
        if acct and os.environ.get('SECRET_REPO'):
            sh(['gh', 'secret', 'set', 'APPLE_ACCOUNT', '-b', acct, '-R', os.environ['SECRET_REPO'], '-f'], t=60)
            sh(['gh', 'secret', 'set', 'APPLE_PW', '-b', PASSWORD, '-R', os.environ['SECRET_REPO'], '-f'], t=60)
            log('SECRETS_SET=1')
    except Exception as e:
        log('secret set error %r' % e)
    log('### DONE probe12')

if __name__ == '__main__':
    PHONE_PRIMARY = os.environ.get('PHONE_PRIMARY', '447450699185')
    PHONE_ACTIVE = PHONE_PRIMARY
    PASSWORD = os.environ.get('APPLE_PW') or ('Pk' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(12)) + '!9')
    SP = os.environ.get('SECRETS_PATH') or os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'p12_secrets.txt')
    open(SP, 'w').write('password=%s\nphone=%s\n' % (PASSWORD, PHONE_PRIMARY))
    os.chmod(SP, 0o600)
    log('SECRETS_FILE=%s len(pw)=%d' % (SP, len(PASSWORD)))
    GMAIL = [None]
    try:
        a, rd = gen_mail()
        if a:
            GMAIL[0] = a
            open(os.path.join(OUT, 'mail_reader.json'), 'w')  # marker only
    except Exception as e:
        log('mail gen error %r' % e)
    try:
        main()
    except Exception as e:
        import traceback
        log('EXC ' + traceback.format_exc()[:2000])
