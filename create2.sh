#!/bin/bash
# round 7: the native create button opened AKAuthorizationRemoteViewService (AXWebApplication) that
# shows Birthday popups AND a critical alert "macOS running on a virtual machine can't be used to
# create a new Apple Account." Round 7 = dismiss the alert, try to actually drive the birthday form
# and press Next, to see whether the VM block is hard (form refuses) or advisory.
# Types nothing personal; submits nothing that could create an account we cannot use.
set -u
OUT="${OUT:-$PWD/out7}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/c7.log"; }
run(){ echo "--- \$ $*" | tee -a "$OUT/c7.log"; "$@" 2>&1 | sed 's/\r//' | head -120 | tee -a "$OUT/c7.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^BEST' "$OUT/$n.ocr.txt" | head -1 | tee -a "$OUT/c7.log"; fi; }
pidof_msg(){ pgrep -x Messages | head -1; }

L "0. VM facts"
run sw_vers -productVersion
run uname -m
run sysctl -n kern.hv_vmm_present
run sysctl -n hw.model
system_profiler SPHardwareDataType 2>/dev/null | head -12 | tee -a "$OUT/hw.txt"

L "1. launch + open create surface"
pkill -x Messages 2>/dev/null; sleep 2; open -a Messages; sleep 9
P=$(./cgui axpid Messages | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/'); echo "pid=${P:-none}" | tee -a "$OUT/c7.log"
[ -n "$P" ] && ./cgui axpressname "$P" "Create New Apple Account" | tee -a "$OUT/c7.log"
sleep 8; shot "r7_00_alert"

L "2. dismiss alert via OK, then re-dump"
[ -n "$P" ] && ./cgui axpressname "$P" "OK" | tee -a "$OUT/c7.log"
sleep 5; shot "r7_01_after_ok"
[ -n "$P" ] && ./cgui axdump "$P" 14 > "$OUT/after_ok.txt" 2>&1
echo "after_ok lines=$(wc -l < "$OUT/after_ok.txt")" | tee -a "$OUT/c7.log"
grep -E 'AXWebArea|AXPopUpButton|AXTextField|AXButton.*(Next|Cancel)|virtual machine' "$OUT/after_ok.txt" | head -25 | tee -a "$OUT/c7.log"

L "3. try to set birthday popups + observe Next enablement"
[ -n "$P" ] && ./cgui axformdump "$P" > "$OUT/form_after_ok.txt" 2>&1
grep -E 'AXPopUpButton|title=\[Next\]|virtual machine' "$OUT/form_after_ok.txt" | head -12 | tee -a "$OUT/c7.log"
[ -n "$P" ] && ./cgui axpress "$P" "Month" 2>&1 | head -3 | tee -a "$OUT/c7.log"
sleep 1; shot "r7_02_month_menu"
[ -n "$P" ] && ./cgui axdump "$P" 12 > "$OUT/month_menu.txt" 2>&1
grep -E 'AXMenuItem|AXMenu ' "$OUT/month_menu.txt" | head -20 | tee -a "$OUT/c7.log"
[ -n "$P" ] && ./cgui keycode 53 >/dev/null 2>&1  # esc closes the popup menu only

L "4. does pressing Next do anything? (Next was enabled=false at first render)"
[ -n "$P" ] && ./cgui axpressname "$P" "Next" | tee -a "$OUT/c7.log"
sleep 6; shot "r7_03_after_next"
[ -n "$P" ] && ./cgui axdump "$P" 14 > "$OUT/after_next.txt" 2>&1
grep -E 'virtual machine|AXTextField|AXPopUpButton|title=\[Next\]|verification' "$OUT/after_next.txt" | head -20 | tee -a "$OUT/c7.log"

L "5. was an AK authorization helper spawned? any network?"
ps -Ao pid,comm | grep -E 'AKAuthorization|appleaccountd|akd' | grep -v grep | tee -a "$OUT/c7.log"
for p in $(pgrep -f AKAuthorizationRemoteViewService 2>/dev/null); do echo "--- lsof $p" | tee -a "$OUT/c7.log"; lsof -nP -p "$p" 2>/dev/null | grep TCP | head -8 | tee -a "$OUT/c7.log"; done

L "6. Apple account state unchanged?"
defaults read MobileMeAccounts 2>&1 | head -3 | tee -a "$OUT/c7.log"
L "DONE7"
