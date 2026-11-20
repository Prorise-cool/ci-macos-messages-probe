#!/bin/bash
# i102962 round 9 — DECISIVE: System Settings Apple Account SIGN-IN (existing Apple ID) on the virtualized runner.
# Round-8 finding: the login pane renders a REAL native credential form (USERNAME_TEXT_FIELD + LOGIN_BUTTON Continue),
# no VM alert on render. Round-8 mistake: the placeholder landed in the search box (field #0), so Continue stayed disabled.
# Round 9: set the field by its AX identifier, confirm Continue becomes enabled, press it ONCE with a placeholder
# address that cannot correspond to any real account, and record whether the next surface is
# (a) a password/verification form  => the VM gate does NOT block login
# (b) the same "running on a virtual machine" critical alert => the gate blocks login too.
# NEVER presses CREATE_BUTTON / "Create New Apple Account". No real credentials. No brute force.
set -u
OUT="${OUT:-$PWD/out9}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/p9.log"; }
TO(){ perl -e 'alarm shift; exec @ARGV' 60 "$@"; }
run(){ echo "--- \$ $*" | tee -a "$OUT/p9.log"; TO "$@" 2>&1 | sed 's/\r//' | head -50 | tee -a "$OUT/p9.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^BEST' "$OUT/$n.ocr.txt" | cut -c1-1000 | head -1 | tee -a "$OUT/p9.log"; fi; }
pids(){ ./cgui list 2>/dev/null | grep -i "owner=$1" | sed -E 's/.*pid=([0-9]+).*/\1/' | sort -u; }
allpids(){ pgrep -f "$1" 2>/dev/null | sort -u; }
VMHITS(){ if grep -q -i -E 'virtual machine|not supported|Use an Apple device|cannot be used|unsupported hardware' "$1" 2>/dev/null; then
    echo "!!! VM_POLICY_TEXT_FOUND in $1" | tee -a "$OUT/p9.log"; grep -n -i -E 'virtual machine|not supported|Use an Apple device|cannot be used|unsupported hardware' "$1" | head -10 | tee -a "$OUT/p9.log"
  else echo "no VM-policy text in $1" | tee -a "$OUT/p9.log"; fi; }
dumpall(){ # $1 label : dump every relevant process tree
  local lbl="$1"
  for pair in "System Settings" "AKAuthorizationRemoteViewService" "akd" "Messages"; do
    for p in $(allpids "$pair"); do
      ./cgui axdump "$p" 20 > "$OUT/${lbl}_$(echo "$pair" | tr ' ' '_')_$p.txt" 2>&1
      echo "dump[$pair pid=$p] lines=$(wc -l < "$OUT/${lbl}_$(echo "$pair" | tr ' ' '_')_$p.txt")" | tee -a "$OUT/p9.log"
    done
  done
  for f in "$OUT/${lbl}_"*.txt; do VMHITS "$f"; done
  echo "--- all static texts seen:" | tee -a "$OUT/p9.log"
  cat "$OUT/${lbl}_"*.txt 2>/dev/null | grep -E 'role=AXStaticText' | sed -E 's/.*title=\[([^]]*)\].*/\1/' | grep -v '^$' | sort -u | head -50 | tee -a "$OUT/${lbl}_texts.txt"
  echo "--- editable / pressable:" | tee -a "$OUT/p9.log"
  cat "$OUT/${lbl}_"*.txt 2>/dev/null | grep -E 'AXSecureTextField|AXTextField|title=\[(Continue|Next|Sign In|OK|Cancel|Not Now|Later|Allow)\]' | grep -v 'AXSearchField' | head -25 | tee -a "$OUT/p9.log"
}

L "0. env"
run sw_vers -productVersion; run sysctl -n kern.hv_vmm_present; run sysctl -n hw.model
RAND=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 10); PROBE_ID="probe-$RAND@example.invalid"
echo "PROBE_ID=$PROBE_ID" | tee -a "$OUT/p9.log"

L "1. Messages FIRST (round-8 raced the launch): does the Messages Sign-In sheet itself show any VM text?"
pkill -x Messages 2>/dev/null; sleep 2; open -a Messages
MP=""; for i in $(seq 1 15); do MP=$(pids Messages | head -1); [ -n "$MP" ] && break; sleep 2; done
echo "Messages pid=${MP:-none}" | tee -a "$OUT/p9.log"
if [ -n "$MP" ]; then
  ./cgui axpressname "$MP" "Sign In" 2>&1 | head -6 | tee -a "$OUT/p9.log"
  sleep 7
  ./cgui axdump "$MP" 18 > "$OUT/m_sheet.txt" 2>&1
  echo "m_sheet_lines=$(wc -l < "$OUT/m_sheet.txt")" | tee -a "$OUT/p9.log"
  shot "r9_00_m_sheet"
  VMHITS "$OUT/m_sheet.txt"
  grep -E 'role=AXStaticText' "$OUT/m_sheet.txt" | sed -E 's/.*title=\[([^]]*)\].*/\1/' | grep -v '^$' | head -20 | tee -a "$OUT/msg_texts.txt"
  grep -E 'AXTextField|AXSecureTextField|title=\[Sign In\]' "$OUT/m_sheet.txt" | head -10 | tee -a "$OUT/p9.log"
  echo "--- fill the sheet's username field by predicate, check Sign In enablement" | tee -a "$OUT/p9.log"
  ./cgui axset "$MP" "email or phone" "$PROBE_ID" 2>&1 | head -3 | tee -a "$OUT/p9.log"
  ./cgui axset "$MP" "_ns:" "$PROBE_ID" 2>&1 | head -3 | tee -a "$OUT/p9.log"
  sleep 2; ./cgui axdump "$MP" 18 > "$OUT/m_sheet_filled.txt" 2>&1
  grep -E 'title=\[Sign In\]|value=\[' "$OUT/m_sheet_filled.txt" | head -8 | tee -a "$OUT/p9.log"
  shot "r9_01_m_filled"
fi

L "2. System Settings Apple Account sign-in pane (fresh)"
pkill -f "System Settings" 2>/dev/null; sleep 2
open "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings"; sleep 15
SP=$(pids "System Settings" | head -1); echo "SystemSettings pid=${SP:-none}" | tee -a "$OUT/p9.log"
[ -z "$SP" ] && { L "NO_SYSTEM_SETTINGS"; }
if [ -n "$SP" ]; then
  ./cgui axdump "$SP" 20 > "$OUT/s_pre.txt" 2>&1
  echo "pre_lines=$(wc -l < "$OUT/s_pre.txt")" | tee -a "$OUT/p9.log"
  grep -E 'USERNAME_TEXT_FIELD|LOGIN_BUTTON|CREATE_BUTTON' "$OUT/s_pre.txt" | head -6 | tee -a "$OUT/p9.log"
  VMHITS "$OUT/s_pre.txt"
  pre_en=$(grep -E 'id=\[LOGIN_BUTTON\]' "$OUT/s_pre.txt" | grep -o 'enabled=[a-z]*' | head -1)
  echo "continue_before=$pre_en" | tee -a "$OUT/p9.log"

  L "2b. set USERNAME_TEXT_FIELD (exact AX identifier) with the placeholder"
  ./cgui axset "$SP" "username_text_field" "$PROBE_ID" 2>&1 | head -4 | tee -a "$OUT/p9.log"
  sleep 2
  ./cgui axdump "$SP" 20 > "$OUT/s_filled.txt" 2>&1
  grep -E 'USERNAME_TEXT_FIELD' "$OUT/s_filled.txt" | head -3 | tee -a "$OUT/p9.log"
  post_en=$(grep -E 'id=\[LOGIN_BUTTON\]' "$OUT/s_filled.txt" | grep -o 'enabled=[a-z]*' | head -1)
  echo "continue_after_fill=$post_en" | tee -a "$OUT/p9.log"
  shot "r9_02_s_filled"

  L "2c. press Continue ONCE (placeholder address; cannot be a real account)"
  ./cgui axpress "$SP" "LOGIN_BUTTON" 2>&1 | head -5 | tee -a "$OUT/p9.log"
  for i in 1 2 3 4; do sleep 6; echo "--- t+$((i*6))s"; shot "r9_03_s_after_$i"; ./cgui list 2>&1 | grep -iE 'owner=(System Settings|akd|Messages)' | head -5 | tee -a "$OUT/p9.log"; done
  L "2d. full multi-process AX dump after submit"
  dumpall "after_continue"
  echo "--- OCR verbatim of the post-submit screen:" | tee -a "$OUT/p9.log"
  grep -h -E '^BEST' "$OUT/r9_03_s_after_4.ocr.txt" 2>/dev/null | cut -c1-1000 | tee -a "$OUT/p9.log"
  echo "--- network held by auth helpers:" | tee -a "$OUT/p9.log"
  for p in $(pgrep -f 'AKAuthorizationRemoteViewService|akd|appleaccountd' 2>/dev/null); do lsof -nP -p "$p" 2>/dev/null | grep TCP | head -6; done | tee -a "$OUT/p9.log"
fi

L "3. account state (must remain untouched)"
run defaults read MobileMeAccounts
echo "accounts_dir:"; ls -l ~/Library/Accounts 2>&1 | head -6 | tee -a "$OUT/p9.log"
sqlite3 ~/Library/Accounts/Accounts4.sqlite "select count(*) from ZACCOUNT;" 2>&1 | head -2 | tee -a "$OUT/p9.log"
echo DONE9 | tee -a "$OUT/p9.log"
