#!/bin/bash
# round 8: (a) fixed AX roots walk; press Create New Apple Account, dismiss the VM alert with OK,
#          then check whether the birthday panel survives and can be driven to Next;
# (b) press System Settings "Don't Have an Account?" (exact normalized) and record what it opens.
# Registers nothing; types no personal data.
set -u
OUT="${OUT:-$PWD/out8}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/c8.log"; }
run(){ echo "--- \$ $*" | tee -a "$OUT/c8.log"; "$@" 2>&1 | sed 's/\r//' | head -100 | tee -a "$OUT/c8.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^BEST' "$OUT/$n.ocr.txt" | head -1 | tee -a "$OUT/c8.log"; fi; }
P_of(){ ./cgui axpid "$1" 2>/dev/null | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/'; }

L "0. vm facts"
run sysctl -n kern.hv_vmm_present; run sysctl -n hw.model

L "1. Messages -> Create New Apple Account"
pkill -x Messages 2>/dev/null; sleep 2; open -a Messages; sleep 9
P=$(P_of Messages); echo "Messages pid=${P:-none}" | tee -a "$OUT/c8.log"
[ -n "$P" ] && ./cgui axpressname "$P" "Create New Apple Account" | tee -a "$OUT/c8.log"
sleep 7; shot "r8_00_alert"
[ -n "$P" ] && ./cgui axdump "$P" 16 > "$OUT/a_alert.txt" 2>&1
echo "alert_lines=$(wc -l < "$OUT/a_alert.txt") vm_text=$(grep -c 'virtual machine' "$OUT/a_alert.txt")" | tee -a "$OUT/c8.log"
grep -E 'virtual machine|title=\[OK\]|AXWebArea|Month|Day|Year|title=\[Next\]' "$OUT/a_alert.txt" | head -12 | tee -a "$OUT/c8.log"

L "2. press OK to dismiss the VM alert, then re-dump"
[ -n "$P" ] && ./cgui axpressname "$P" "OK" | tee -a "$OUT/c8.log"
sleep 5; shot "r8_01_after_ok"
[ -n "$P" ] && ./cgui axdump "$P" 16 > "$OUT/a_after_ok.txt" 2>&1
echo "after_ok_lines=$(wc -l < "$OUT/a_after_ok.txt") vm_text=$(grep -c 'virtual machine' "$OUT/a_after_ok.txt") webarea=$(grep -c AXWebArea "$OUT/a_after_ok.txt")" | tee -a "$OUT/c8.log"
grep -E 'virtual machine|AXWebArea|Birthday|Month|Day|Year|title=\[Next\]|title=\[Cancel\]|AXTextField|AXSecureTextField' "$OUT/a_after_ok.txt" | head -20 | tee -a "$OUT/c8.log"

L "3. if the birthday panel survives: set month popup and see whether Next becomes enabled"
if grep -q 'value=\[Month\]' "$OUT/a_after_ok.txt"; then
  [ -n "$P" ] && ./cgui axpressname "$P" "Month" | tee -a "$OUT/c8.log"
  sleep 2; shot "r8_02_month_menu"
  [ -n "$P" ] && ./cgui axdump "$P" 16 > "$OUT/a_month_menu.txt" 2>&1
  grep -E 'AXMenuItem' "$OUT/a_month_menu.txt" | head -14 | tee -a "$OUT/c8.log"
  [ -n "$P" ] && ./cgui axpressname "$P" "March" | tee -a "$OUT/c8.log"
  sleep 2; shot "r8_03_after_month"
  [ -n "$P" ] && ./cgui axdump "$P" 16 > "$OUT/a_after_month.txt" 2>&1
  grep -E 'value=\[March\]|title=\[Next\]|Month|Day|Year' "$OUT/a_after_month.txt" | head -10 | tee -a "$OUT/c8.log"
  [ -n "$P" ] && ./cgui axpressname "$P" "Next" | tee -a "$OUT/c8.log"
  sleep 6; shot "r8_04_after_next"
  [ -n "$P" ] && ./cgui axdump "$P" 16 > "$OUT/a_after_next.txt" 2>&1
  grep -E 'virtual machine|AXTextField|AXSecureTextField|AXPopUpButton|title=\[Next\]|title=\[Continue\]|Don' "$OUT/a_after_next.txt" | head -16 | tee -a "$OUT/c8.log"
else
  echo "birthday panel gone after OK (form closed by the VM block)" | tee -a "$OUT/c8.log"
fi

L "4. System Settings 'Don't Have an Account?' -> what does it open?"
open "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings" 2>/dev/null; sleep 14
SP=$(P_of "System Settings"); echo "SystemSettings pid=${SP:-none}" | tee -a "$OUT/c8.log"
if [ -n "$SP" ]; then
  ./cgui axdump "$SP" 14 > "$OUT/s_before.txt" 2>&1
  grep -E 'CREATE_BUTTON|USERNAME_TEXT_FIELD|LOGIN_BUTTON|FORGOT_BUTTON' "$OUT/s_before.txt" | head -6 | tee -a "$OUT/c8.log"
  ./cgui axpressname "$SP" "Don’t Have an Account?" | tee -a "$OUT/c8.log"
  sleep 12; shot "r8_05_ss_after_create"
  ./cgui axdump "$SP" 16 > "$OUT/s_after.txt" 2>&1
  echo "ss_after_lines=$(wc -l < "$OUT/s_after.txt") vm_text=$(grep -c 'virtual machine' "$OUT/s_after.txt") webarea=$(grep -c AXWebArea "$OUT/s_after.txt")" | tee -a "$OUT/c8.log"
  grep -E 'virtual machine|AXWebArea|AXTextField|AXSecureTextField|title=\[Next\]|title=\[Continue\]|Sign|Don' "$OUT/s_after.txt" | head -20 | tee -a "$OUT/c8.log"
fi
./cgui list 2>&1 | head -14 | tee -a "$OUT/c8.log"

L "5. state"
defaults read MobileMeAccounts 2>&1 | head -2 | tee -a "$OUT/c8.log"
L "DONE8"
