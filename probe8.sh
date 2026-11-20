#!/bin/bash
# i102962 round 8 — SCOPE OF THE APPLE VM GATE: does it block LOGIN (existing Apple ID) too, or only CREATE?
# NEVER presses "Create New Apple Account". Never touches a real account.
# Only a single non-guessing probe: placeholder address probe-<rand>@example.invalid + placeholder password,
# submitted at most once per surface, to see whether the VM policy rejects the *channel* or the *credentials*.
set -u
OUT="${OUT:-$PWD/out8}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/p8.log"; }
TO(){ perl -e 'alarm shift; exec @ARGV' 60 "$@"; }
run(){ echo "--- \$ $*" | tee -a "$OUT/p8.log"; TO "$@" 2>&1 | sed 's/\r//' | head -60 | tee -a "$OUT/p8.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^BEST' "$OUT/$n.ocr.txt" | cut -c1-900 | head -1 | tee -a "$OUT/p8.log"; fi; }
pids(){ ./cgui list 2>/dev/null | grep -i "owner=$1" | sed -E 's/.*pid=([0-9]+).*/\1/' | sort -u; }
VMHITS(){ grep -n -i -E 'virtual machine|not supported|Use an Apple device|cannot be used|Cloud Mac|unsupported' "$1" | head -20 | tee -a "$OUT/p8.log"; }

L "0. environment / virtualization facts"
run sw_vers -productVersion
run uname -m
run sysctl -n kern.hv_vmm_present
run sysctl -n hw.model
echo "RAND=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8)" > "$OUT/rand.txt"; . "$OUT/rand.txt"
PROBE_ID="probe-$RAND@example.invalid"; echo "PROBE_ID=$PROBE_ID" | tee -a "$OUT/p8.log"

L "1. where does the VM string live on disk? (local frameworks, read-only)"
for f in /System/Library/PrivateFrameworks/AuthKit.framework/Versions/A/AuthKit \
         /System/Library/PrivateFrameworks/AuthKitUI.framework/Versions/A/AuthKitUI \
         /System/Library/PrivateFrameworks/AppleAccount.framework/Versions/A/AppleAccount; do
  [ -f "$f" ] || continue
  n=$(strings -a "$f" 2>/dev/null | grep -c -i "virtual machine")
  echo "binary=$f vm_strings=$n" | tee -a "$OUT/p8.log"
  [ "$n" -gt 0 ] && strings -a "$f" 2>/dev/null | grep -n -i -B2 -A4 "virtual machine" | head -40 | tee -a "$OUT/p8.txt"
done
# every framework that carries the exact alert text
L "1b. which binaries carry 'can.t be used to create a new Apple Account'"
for d in /System/Library/PrivateFrameworks /System/Library/Frameworks /usr/libexec /System/Library/CoreServices; do
  find "$d" -maxdepth 2 -type f -perm -u+r 2>/dev/null | head -400
done > "$OUT/cand.txt"
echo "candidates=$(wc -l < "$OUT/cand.txt")" | tee -a "$OUT/p8.log"
while read -r f; do
  if strings -a "$f" 2>/dev/null | grep -q "can't be used to create a new Apple Account"; then
    echo "HIT_VM_CREATE_TEXT=$f" | tee -a "$OUT/p8.log"
    strings -a "$f" | grep -i -B3 -A3 "can't be used to create a new Apple Account" | head -30 | tee -a "$OUT/vm_text_context.txt"
  fi
done < "$OUT/cand.txt"

L "2. Messages: open Sign In sheet (SIGN IN ONLY, never Create)"
pkill -x Messages 2>/dev/null; sleep 2; open -a Messages; sleep 10
MP=$(pids Messages | head -1); echo "Messages pid=${MP:-none}" | tee -a "$OUT/p8.log"
if [ -z "$MP" ]; then echo "NO_MESSAGES pid - abort section 2"; else
  ./cgui axwinls "$MP" > "$OUT/msg_wins_before.txt" 2>&1
  ./cgui axpressname "$MP" "Sign In" 2>&1 | head -8 | tee -a "$OUT/p8.log"
  sleep 6
  ./cgui axwinls "$MP" > "$OUT/msg_wins_sheet.txt" 2>&1; cat "$OUT/msg_wins_sheet.txt" | tee -a "$OUT/p8.log"
  ./cgui axdump "$MP" 16 > "$OUT/msg_sheet_ax.txt" 2>&1
  echo "sheet_ax_lines=$(wc -l < "$OUT/msg_sheet_ax.txt")" | tee -a "$OUT/p8.log"
  grep -E 'AXTextField|AXSecureTextField|AXButton|AXStaticText|AXSheet|AXDialog' "$OUT/msg_sheet_ax.txt" | sed -n 1,60p | tee -a "$OUT/p8.log"
  shot "r8_00_msg_sheet"
  VMHITS "$OUT/msg_sheet_ax.txt"
  echo "--- VM text on the sheet itself (verbatim static texts):" | tee -a "$OUT/p8.log"
  grep -E 'role=AXStaticText' "$OUT/msg_sheet_ax.txt" | sed -E 's/.*title=\[([^]]*)\].*/\1/' | grep -v '^$' | tee -a "$OUT/msg_statictexts.txt"

  L "2b. fill placeholder address -> is Sign In enabled? (no submit yet)"
  for SUB in AXDialog AXSheet; do
    ./cgui axfillin "$MP" "$SUB" "$PROBE_ID" 2>&1 | head -4 | tee -a "$OUT/p8.log"
  done
  sleep 2
  ./cgui axdump "$MP" 16 > "$OUT/msg_after_fill.txt" 2>&1
  echo "--- Sign In / Continue buttons after fill:" | tee -a "$OUT/p8.log"
  grep -iE 'title=\[(Sign In|Continue|Next)\]' "$OUT/msg_after_fill.txt" | head -6 | tee -a "$OUT/p8.log"
  echo "--- filled field readback:" | tee -a "$OUT/p8.log"
  grep -E "value=\[$PROBE_ID\]" "$OUT/msg_after_fill.txt" | head -3 | tee -a "$OUT/p8.log"
  shot "r8_01_msg_filled"

  L "2c. ONE non-guessing submit: press Sign In with the placeholder address"
  PRESSED=0
  for SUB in AXDialog AXSheet; do
    o=$(./cgui axpressin "$MP" "$SUB" "Sign In" 2>&1); echo "$o" | tee -a "$OUT/p8.log"
    echo "$o" | grep -q 'rc=0' && PRESSED=1 && break
  done
  [ "$PRESSED" = 0 ] && { echo "--- fallback: press by name" | tee -a "$OUT/p8.log"; ./cgui axpressname "$MP" "Sign In" 2>&1 | head -6 | tee -a "$OUT/p8.log"; }
  sleep 12
  shot "r8_02_msg_after_signin"
  ./cgui axwinls "$MP" > "$OUT/msg_wins_after.txt" 2>&1; cat "$OUT/msg_wins_after.txt" | tee -a "$OUT/p8.log"
  ./cgui axdump "$MP" 18 > "$OUT/msg_after_signin.txt" 2>&1
  echo "--- after-submit texts:" | tee -a "$OUT/p8.log"
  grep -E 'role=AXStaticText' "$OUT/msg_after_signin.txt" | sed -E 's/.*title=\[([^]]*)\].*/\1/' | grep -v '^$' | tee -a "$OUT/msg_after_signin_texts.txt"
  echo "--- new fields (password?) / buttons / alerts:" | tee -a "$OUT/p8.log"
  grep -iE 'AXSecureTextField|title=\[(Sign In|Continue|OK|Cancel|Not Now|Later)\]|AXSheet|AXDialog' "$OUT/msg_after_signin.txt" | head -20 | tee -a "$OUT/p8.log"
  VMHITS "$OUT/msg_after_signin.txt"
  echo "--- OCR of the post-submit screen:" | tee -a "$OUT/p8.log"
  grep -h -E '^BEST' "$OUT/r8_02_msg_after_signin.ocr.txt" 2>/dev/null | cut -c1-600 | tee -a "$OUT/p8.log"
fi

L "3. System Settings > Apple Account panel: enumerate only, then one placeholder submit"
open "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings"; sleep 16
SP=$(pids "System Settings" | head -1); echo "SystemSettings pid=${SP:-none}" | tee -a "$OUT/p8.log"
if [ -n "$SP" ]; then
  ./cgui axdump "$SP" 18 > "$OUT/set_pre.txt" 2>&1
  echo "set_pre_lines=$(wc -l < "$OUT/set_pre.txt")" | tee -a "$OUT/p8.log"
  grep -E 'role=AXStaticText' "$OUT/set_pre.txt" | sed -E 's/.*title=\[([^]]*)\].*/\1/' | grep -v '^$' | head -40 | tee -a "$OUT/set_pre_texts.txt"
  echo "--- actionable entries:" | tee -a "$OUT/p8.log"
  grep -iE 'title=\[(Sign In|Continue|Apple Account|Sign In\.\.\.|Set Up|Not Now|Create|Have an Account|Don.t Have)' "$OUT/set_pre.txt" | head -20 | tee -a "$OUT/p8.log"
  VMHITS "$OUT/set_pre.txt"
  shot "r8_03_settings_pre"
  # enter the sign-in surface (choose the Sign In entry, never the create one)
  for NEEDLE in "Sign In" "Sign In…" "Set Up"; do
    o=$(./cgui axpress "$SP" "$NEEDLE" 2>&1); echo "press[$NEEDLE]: $(echo "$o" | tr '\n' ' ' | cut -c1-300)" | tee -a "$OUT/p8.log"
    echo "$o" | grep -q 'rc=0' && break
  done
  sleep 10
  shot "r8_04_settings_signin"
  ./cgui axdump "$SP" 18 > "$OUT/set_after.txt" 2>&1
  echo "--- texts after entering sign-in surface:" | tee -a "$OUT/p8.log"
  grep -E 'role=AXStaticText' "$OUT/set_after.txt" | sed -E 's/.*title=\[([^]]*)\].*/\1/' | grep -v '^$' | head -40 | tee -a "$OUT/set_after_texts.txt"
  echo "--- fields/buttons:" | tee -a "$OUT/p8.log"
  grep -iE 'AXTextField|AXSecureTextField|title=\[(Continue|Next|Sign In|OK|Cancel)\]|AXWebArea' "$OUT/set_after.txt" | head -20 | tee -a "$OUT/p8.log"
  VMHITS "$OUT/set_after.txt"
  # fill placeholder + one submit, only if a text field exists
  if grep -q 'AXTextField' "$OUT/set_after.txt"; then
    ./cgui axfilln "$SP" 0 "$PROBE_ID" 2>&1 | head -6 | tee -a "$OUT/p8.log"
    sleep 2
    for NEEDLE in "Continue" "Next"; do
      o=$(./cgui axpress "$SP" "$NEEDLE" 2>&1); echo "press[$NEEDLE]: $(echo "$o" | tr '\n' ' ' | cut -c1-300)" | tee -a "$OUT/p8.log"
      echo "$o" | grep -q 'rc=0' && break
    done
    sleep 12
    shot "r8_05_settings_after_submit"
    ./cgui axdump "$SP" 18 > "$OUT/set_after_submit.txt" 2>&1
    echo "--- after-submit texts:" | tee -a "$OUT/p8.log"
    grep -E 'role=AXStaticText' "$OUT/set_after_submit.txt" | sed -E 's/.*title=\[([^]]*)\].*/\1/' | grep -v '^$' | head -40 | tee -a "$OUT/p8.log"
    VMHITS "$OUT/set_after_submit.txt"
    echo "--- any auth helper spawned / network:" | tee -a "$OUT/p8.log"
    ps -Ao pid,comm | grep -E 'AKAuthorization|akd|appleaccountd|WebContent|SafariViewService' | grep -v grep | tee -a "$OUT/p8.log"
    for p in $(pgrep -f 'AKAuthorizationRemoteViewService|WebContent|SafariViewService' 2>/dev/null); do lsof -nP -p "$p" 2>/dev/null | grep TCP | head -5; done | tee -a "$OUT/p8.log"
  fi
fi

L "4. account state (must be untouched)"
defaults read MobileMeAccounts 2>&1 | head -6 | tee -a "$OUT/p8.log"
ls ~/Library/Accounts 2>&1 | head -5 | tee -a "$OUT/p8.log"
echo DONE8 | tee -a "$OUT/p8.log"
