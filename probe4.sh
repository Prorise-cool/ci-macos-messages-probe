#!/bin/bash
# round 4: same goals as round 3 but pid resolution hardened (CGWindowList may be empty under
# the runner session; fall back to pgrep -x Messages). SENDS NOTHING.
set -u
OUT="${OUT:-$PWD/out4}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/probe4.log"; }
R(){ echo "--- \$ $*" | tee -a "$OUT/probe4.log"; }
run(){ R "$@"; "$@" 2>&1 | sed 's/\r//' | head -140 | tee -a "$OUT/probe4.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^BEST' "$OUT/$n.ocr.txt" | head -1 | tee -a "$OUT/probe4.log"; fi; }
pidof_msg(){ pgrep -x Messages | head -1; }
alive(){ local p="$1"; if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "ALIVE pid=$p"; else echo "DEAD pid=${p:-none}"; fi; }
winlist(){ ./cgui list > "$OUT/$1.txt" 2>&1; echo "list_lines=$(wc -l < "$OUT/$1.txt") msg_lines=$(grep -c 'owner=Messages' "$OUT/$1.txt" || true)" | tee -a "$OUT/probe4.log"; grep 'owner=Messages' "$OUT/$1.txt" | head -4 | tee -a "$OUT/probe4.log"; }

L "0. build check"
ls -l cgui ocr | tee -a "$OUT/probe4.log"
echo "grep-AXValueGetValue-in-source=$(grep -c AXValueGetValue cgui.swift)" | tee -a "$OUT/probe4.log"
echo "grep-axwinls-in-source=$(grep -c axwinls cgui.swift)" | tee -a "$OUT/probe4.log"

L "1. launch + pid resolution"
open -a Messages; sleep 10
./cgui ax | tee -a "$OUT/probe4.log"
P=$(pidof_msg); echo "MPID=$P" | tee -a "$OUT/probe4.log"
winlist "w1_list"
shot "r4_00_launch"
[ -n "$P" ] && { ./cgui axwinls "$P" > "$OUT/w1_axwinls.txt" 2>&1; cat "$OUT/w1_axwinls.txt" | tee -a "$OUT/probe4.log"; }

L "2. AXdump: decoded coordinates proof (old build printed pos=<__NSCFType>)"
if [ -n "$P" ]; then
  ./cgui axdump "$P" 10 > "$OUT/w1_axdump.txt" 2>&1
  echo "raw_typename_lines=$(grep -c '__NSCFType' "$OUT/w1_axdump.txt")" | tee -a "$OUT/probe4.log"
  echo "decoded_pos_lines=$(grep -c 'pos=[0-9-]' "$OUT/w1_axdump.txt")" | tee -a "$OUT/probe4.log"
  echo "decoded_center_lines=$(grep -c 'center=' "$OUT/w1_axdump.txt")" | tee -a "$OUT/probe4.log"
  grep 'pos=[0-9-]' "$OUT/w1_axdump.txt" | head -10 | tee -a "$OUT/probe4.log"
fi

L "3. axfind Sign In + axpress -> sign-in sheet; dump sheet with coordinates"
if [ -n "$P" ]; then
  ./cgui axfind "$P" "sign in" > "$OUT/w1_axfind_signin.txt" 2>&1
  head -6 "$OUT/w1_axfind_signin.txt" | tee -a "$OUT/probe4.log"
  ./cgui axpress "$P" "Sign In" | tee -a "$OUT/probe4.log"
  sleep 6
  shot "r4_01_sheet"
  ./cgui axwinls "$P" > "$OUT/w2_axwinls.txt" 2>&1; cat "$OUT/w2_axwinls.txt" | tee -a "$OUT/probe4.log"
  ./cgui axdump "$P" 10 > "$OUT/w2_axdump.txt" 2>&1
  echo "sheet_decoded_pos=$(grep -c 'pos=[0-9-]' "$OUT/w2_axdump.txt")" | tee -a "$OUT/probe4.log"
  grep -n -E 'AXTextField|AXSecureTextField|AXButton|AXSheet|AXDialog|Sign In|Cancel|Email or Phone' "$OUT/w2_axdump.txt" | head -22 | tee -a "$OUT/probe4.log"
fi

L "4. axset / axfillin into the sign-in sheet (dummy, never submitted)"
if [ -n "$P" ]; then
  ./cgui axset "$P" "Email or Phone" "probe-dummy@example.invalid" | tee -a "$OUT/probe4.log"
  ./cgui axfillin "$P" "AXDialog" "probe-dummy2@example.invalid" | tee -a "$OUT/probe4.log"
  sleep 1; shot "r4_02_sheet_filled"
fi

L "5. closing-method matrix (which dismissal keeps Messages alive?)"
echo "before=$(alive "$P")" | tee -a "$OUT/probe4.log"
L "5a esc (keycode 53)"
./cgui keycode 53 | tee -a "$OUT/probe4.log"; sleep 4; shot "r4_03_after_esc"
echo "after_esc=$(alive "$P")" | tee -a "$OUT/probe4.log"
L "5b cmd+w (keycode 13 with command)"
./cgui cmdkey 13 | tee -a "$OUT/probe4.log"; sleep 4; shot "r4_04_after_cmdw"
echo "after_cmdw=$(alive "$P")" | tee -a "$OUT/probe4.log"
L "5c AXCloseButton inside the dialog"
if [ -n "$P" ]; then ./cgui axpressin "$P" "AXDialog" "close button" | tee -a "$OUT/probe4.log"; fi
sleep 4; shot "r4_05_after_closebtn"
echo "after_closebtn=$(alive "$P")" | tee -a "$OUT/probe4.log"
L "5d Cancel button (expected to quit Messages)"
if [ -n "$P" ]; then ./cgui axpressin "$P" "AXDialog" "Cancel" | tee -a "$OUT/probe4.log"; fi
sleep 5; shot "r4_06_after_cancel"
echo "after_cancel=$(alive "$P")" | tee -a "$OUT/probe4.log"

L "6. relaunch -> compose reachability: messageBodyField + sms://open draft"
open -a Messages; sleep 10
P2=$(pidof_msg); echo "MPID2=$P2" | tee -a "$OUT/probe4.log"
winlist "w3_list"
if [ -n "$P2" ]; then
  ./cgui front Messages >/dev/null 2>&1; sleep 1
  ./cgui axdump "$P2" 12 > "$OUT/w3_axdump.txt" 2>&1
  echo "relaunch_bodyfield_hits=$(grep -c 'messageBodyField' "$OUT/w3_axdump.txt")" | tee -a "$OUT/probe4.log"
  ./cgui axfind "$P2" "messagebodyfield" > "$OUT/w3_axfind_body.txt" 2>&1
  head -4 "$OUT/w3_axfind_body.txt" | tee -a "$OUT/probe4.log"
  ./cgui axset "$P2" "messagebodyfield" "PROBE_MARKER_i102896_DO_NOT_SEND" | tee -a "$OUT/probe4.log"
  sleep 1; shot "r4_07_compose_draft"
fi

L "7. two-stage gate (login state first, compose second)"
run python3 messages_login_send.py stage --outdir "$OUT/stage" --type-text "PROBE_MARKER_i102896_DO_NOT_SEND"
python3 - "$OUT/stage/stage.json" <<'PY' | tee -a "$OUT/probe4.log"
import json,sys
d=json.load(open(sys.argv[1]))
print('STAGE=',d.get('stage'),'signed_in=',d.get('signed_in'),'nothing_sent=',d.get('nothing_sent'),'min_input=',json.dumps(d.get('min_input'))[:300])
PY

L "8. chat.db snapshot (proves nothing sent)"
{ sqlite3 -readonly ~/Library/Messages/chat.db "select count(*) from message" 2>&1;
  sqlite3 -readonly ~/Library/Messages/chat.db "select count(*) from handle" 2>&1; } | tee -a "$OUT/probe4.log"
alive "$P2" | tee -a "$OUT/probe4.log"
L "DONE4"
