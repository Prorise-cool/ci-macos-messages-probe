#!/bin/bash
# i103082 round 10 — DECISIVE, System Settings single leg (Messages leg dropped; round-9 hung on a
# `tr -dc < /dev/urandom | head` pipeline before it ever touched the login surface).
# Question: on a virtualized GitHub macos runner, when an EXISTING Apple ID is submitted on the
# System Settings > Apple Account sign-in pane (LOGIN_BUTTON Continue, NOT Create), does the next
# surface become a password / 2FA form (=> VM gate does not block LOGIN) or the same
# "macOS running on a virtual machine ..." critical alert (=> gate blocks login too)?
# Guardrails: NEVER presses CREATE_BUTTON / "Create New Apple Account". No real credentials.
# Exactly ONE submit with a placeholder address that cannot map to a real account. No brute force.
set -u
OUT="${OUT:-$PWD/out10}"; mkdir -p "$OUT"
LOG="$OUT/p10.log"
L(){ echo "=== $(date -u +%H:%M:%S) $* ===" | tee -a "$LOG"; }
TO(){ perl -e 'alarm shift; exec @ARGV' "$@"; }
run(){ echo "--- \$ $*" | tee -a "$LOG"; TO 40 "$@" 2>&1 | sed 's/\r//' | head -60 | tee -a "$LOG"; }
pids(){ TO 30 ./cgui list 2>/dev/null | grep -i "owner=$1" | sed -E 's/.*pid=([0-9]+).*/\1/' | sort -u; }
allpids(){ pgrep -f "$1" 2>/dev/null | sort -u; }
shot(){ local n="$1"; TO 25 screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then TO 45 ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^BEST' "$OUT/$n.ocr.txt" 2>/dev/null | cut -c1-1200 | head -1 | tee -a "$LOG"; fi; }
VMHITS(){ if grep -v -i 'Specifications' "$1" 2>/dev/null | grep -q -i -E 'virtual machine|Use an Apple device|cannot be used|not supported on this'; then
    echo "!!! VM_POLICY_TEXT_FOUND in $1" | tee -a "$LOG"; grep -v -i 'Specifications' "$1" | grep -n -i -E 'virtual machine|Use an Apple device|cannot be used|not supported on this' | head -10 | tee -a "$LOG"
    case "$1" in *after_continue*) echo "Y" > "$OUT/vm_flag";; esac
  else echo "no VM-policy text in $1" | tee -a "$LOG"; fi; }
adump(){ # label pid depth
  local lbl="$1"
  local pid="$2"
  local dep="${3:-22}"
  local f="$OUT/${lbl}.txt"
  echo "--- axdump $lbl pid=$pid depth=$dep" | tee -a "$LOG"
  TO 60 ./cgui axdump "$pid" "$dep" > "$f" 2>&1
  echo "dump[$lbl] lines=$(wc -l < "$f" 2>/dev/null || echo 0)" | tee -a "$LOG"
  VMHITS "$f"
}
dumpall(){ local lbl="$1"
  for pair in "System Settings" "AKAuthorizationRemoteViewService" "akd" "appleaccountd" "Messages"; do
    for p in $(allpids "$pair"); do adump "${lbl}_$(echo "$pair" | tr ' ' '_')_$p" "$p" 22; done
  done
  echo "--- static texts after [$lbl]:" | tee -a "$LOG"
  cat "$OUT/${lbl}_"*.txt 2>/dev/null | grep -E 'role=AXStaticText' | sed -E 's/.*title=\[([^]]*)\].*/\1/' | grep -v '^$' | sort -u | head -60 | tee -a "$OUT/${lbl}_texts.txt"
  echo "--- secure/text fields + buttons after [$lbl]:" | tee -a "$LOG"
  cat "$OUT/${lbl}_"*.txt 2>/dev/null | grep -E 'AXSecureTextField|role=AXTextField|title=\[(Continue|Next|Sign In|OK|Cancel|Not Now|Later|Allow|Done)\]' | grep -v 'AXSearchField' | head -30 | tee -a "$LOG"
}

PROBE_ID="probe-$(date +%s)-$$@example.invalid"
L "0. env"
run sw_vers -productVersion; run sysctl -n kern.hv_vmm_present; run sysctl -n hw.model
echo "PROBE_ID=$PROBE_ID (placeholder, cannot map to a real Apple Account)" | tee -a "$LOG"

L "1. open System Settings Apple Account pane (fresh)"
pkill -f "System Settings" 2>/dev/null; sleep 2
open "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings" >/dev/null 2>&1
SP=""
for i in $(seq 1 30); do SP=$(pids "System Settings" | head -1); [ -n "$SP" ] && break; sleep 2; done
echo "SystemSettings pid=${SP:-none}" | tee -a "$LOG"
[ -z "$SP" ] && { echo "VERDICT=NO_SYSTEM_SETTINGS" | tee -a "$LOG"; echo DONE10 | tee -a "$LOG"; exit 0; }
sleep 12
shot "r10_00_settings"
adump "pre" "$SP" 26
echo "--- id hits pre:" | tee -a "$LOG"
grep -E 'USERNAME_TEXT_FIELD|LOGIN_BUTTON|CREATE_BUTTON' "$OUT/pre.txt" | head -10 | tee -a "$LOG"
echo "--- owner list:" | tee -a "$LOG"; TO 30 ./cgui list 2>&1 | grep -iE 'owner=(System Settings|akd|appleaccountd|Messages)' | head -8 | tee -a "$LOG"

L "2. fill USERNAME_TEXT_FIELD with the placeholder"
FILLED=N
TO 60 ./cgui axset "$SP" "username_text_field" "$PROBE_ID" 2>&1 | head -6 | tee -a "$LOG"
sleep 2
adump "filled" "$SP" 26
grep -E 'id=\[USERNAME_TEXT_FIELD\]' "$OUT/filled.txt" | head -3 | tee -a "$LOG"
if ! grep -qE "value=\[${PROBE_ID//+/\\+}" "$OUT/filled.txt" 2>/dev/null; then
  L "2b. fallback: focus the field and type via CGEvent"
  TO 40 ./cgui axfocus "$SP" "username_text_field" 2>&1 | head -4 | tee -a "$LOG"
  TO 30 ./cgui key "$PROBE_ID" 2>&1 | head -4 | tee -a "$LOG"
  sleep 2; adump "filled2" "$SP" 26
  grep -E 'id=\[USERNAME_TEXT_FIELD\]' "$OUT/filled2.txt" | head -3 | tee -a "$LOG"
fi
FILL_FILE="$OUT/filled.txt"; [ -f "$OUT/filled2.txt" ] && FILL_FILE="$OUT/filled2.txt"
post_en=$(grep -E 'id=\[LOGIN_BUTTON\]' "$FILL_FILE" | grep -o 'enabled=[a-z]*' | head -1)
echo "continue_enabled=$post_en" | tee -a "$LOG"
shot "r10_01_filled"

L "3. press Continue (LOGIN_BUTTON) ONCE — placeholder address only"
TO 40 ./cgui axpress "$SP" "LOGIN_BUTTON" 2>&1 | head -5 | tee -a "$LOG"
if [ "$post_en" != "enabled=true" ]; then
  L "3b. Continue reported not-enabled; press Return (36) once inside the focused field as a second (single) submit attempt"
  TO 40 ./cgui axfocus "$SP" "username_text_field" 2>&1 | head -3 | tee -a "$LOG"
  TO 30 ./cgui keycode 36 2>&1 | head -3 | tee -a "$LOG"
fi
for i in 1 2 3 4 5; do sleep 8; echo "--- t+$((i*8))s"; shot "r10_02_after_$i"; TO 30 ./cgui list 2>&1 | grep -iE 'owner=(System Settings|akd|appleaccountd|Messages|AKAuthorization)' | head -6 | tee -a "$LOG"; done

L "4. full multi-process AX dump after submit"
dumpall "after_continue"
echo "--- OCR verbatim of the post-submit screen:" | tee -a "$LOG"
grep -h -E '^BEST' "$OUT/r10_02_after_5.ocr.txt" 2>/dev/null | cut -c1-1200 | tee -a "$LOG"
echo "--- network held by auth helpers:" | tee -a "$LOG"
for p in $(pgrep -f 'AKAuthorizationRemoteViewService|akd|appleaccountd' 2>/dev/null); do TO 20 lsof -nP -p "$p" 2>/dev/null | grep TCP | head -4; done | tee -a "$LOG"

L "5. VERDICT"
ALL="$OUT/after_continue_texts.txt"
cat "$OUT/after_continue_"*.txt 2>/dev/null > "$OUT/after_all.txt"
OCRALL="$OUT/r10_02_after_4.ocr.txt $OUT/r10_02_after_5.ocr.txt"
V="UNKNOWN"
if grep -v -i 'Specifications' "$OUT/after_all.txt" 2>/dev/null | grep -q -i -E 'virtual machine|Use an Apple device|cannot be used|not supported on this' || grep -q -i -E 'virtual machine|Use an Apple device|cannot be used|not supported on this' $OCRALL 2>/dev/null; then V="VM_ALERT"
elif grep -q -i 'AXSecureTextField' "$OUT/after_all.txt" 2>/dev/null; then V="PASSWORD_FIELD"
elif grep -q -iE 'password|verification code|two-factor|two factor|6-digit|trusted device' "$OUT/after_all.txt" $OCRALL 2>/dev/null; then V="PASSWORD_OR_2FA_TEXT"
elif grep -q -iE 'not found|could not|incorrect|invalid|unable to|does not exist|couldn.t' "$OUT/after_all.txt" $OCRALL 2>/dev/null; then V="SERVER_REJECTED_AUTH_REACHABLE"
fi
[ -f "$OUT/vm_flag" ] && V="VM_ALERT"
echo "VERDICT=$V" | tee -a "$LOG"
echo "--- post-submit texts (unique) ---" | tee -a "$LOG"; head -60 "$OUT/after_continue_texts.txt" 2>/dev/null | tee -a "$LOG"

L "6. account state (must remain untouched)"
run defaults read MobileMeAccounts
echo "accounts_dir:"; ls -l ~/Library/Accounts 2>&1 | head -6 | tee -a "$LOG"
sqlite3 ~/Library/Accounts/Accounts4.sqlite "select count(*) from ZACCOUNT;" 2>&1 | head -2 | tee -a "$LOG"
echo DONE10 | tee -a "$LOG"
