#!/bin/bash
# round 5: (1) each dismissal method tested on a FRESH Messages launch (round-4 flaw: first esc
#          killed the process so the rest of the matrix measured a dead pid);
#          (2) compose reachability: does sms://open produce messageBodyField while signed OUT?
#          (3) after axfillin of the Apple ID field does the Sign In button become enabled?
# SENDS NOTHING. Never presses Return in a chat window.
set -u
OUT="${OUT:-$PWD/out5}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/probe5.log"; }
R(){ echo "--- \$ $*" | tee -a "$OUT/probe5.log"; }
run(){ R "$@"; "$@" 2>&1 | sed 's/\r//' | head -120 | tee -a "$OUT/probe5.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^BEST' "$OUT/$n.ocr.txt" | head -1 | tee -a "$OUT/probe5.log"; fi; }
pidof_msg(){ pgrep -x Messages | head -1; }
alive(){ local p="$1"; if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "ALIVE pid=$p"; else echo "DEAD pid=${p:-none}"; fi; }
killmsg(){ pkill -x Messages 2>/dev/null; sleep 2; pkill -9 -x Messages 2>/dev/null; sleep 1; }
fresh(){ killmsg; open -a Messages; sleep 9; P=$(pidof_msg); echo "fresh pid=${P:-none} $(alive "$P")" | tee -a "$OUT/probe5.log"; }
sheet(){ [ -n "$P" ] && ./cgui axpress "$P" "Sign In" | tee -a "$OUT/probe5.log"; sleep 5; }
row(){ echo "RESULT method=$1 pid=$2 before=ALIVE after=$(alive "$2")" | tee -a "$OUT/probe5.log"; }

L "0. build check"
ls -l cgui ocr | tee -a "$OUT/probe5.log"
echo "src_AXValueGetValue=$(grep -c AXValueGetValue cgui.swift) src_axwinls=$(grep -c axwinls cgui.swift)" | tee -a "$OUT/probe5.log"

L "1. method matrix - each on a FRESH launch"
L "1A esc (keycode 53) on the sign-in sheet"
fresh; sheet; shot "r5_A_before_esc"
[ -n "$P" ] && ./cgui keycode 53 >/dev/null 2>&1; sleep 4; shot "r5_A_after_esc"; row "esc" "$P"

L "1B cmd+w on the sign-in sheet"
fresh; sheet
[ -n "$P" ] && ./cgui cmdkey 13 >/dev/null 2>&1; sleep 4; shot "r5_B_after_cmdw"; row "cmd+w" "$P"

L "1C AXCloseButton press inside the sheet"
fresh; sheet
[ -n "$P" ] && ./cgui axpressin "$P" "AXDialog" "close button" | tee -a "$OUT/probe5.log"; sleep 4; shot "r5_C_after_closebtn"; row "axclose" "$P"

L "1D Cancel button press"
fresh; sheet
[ -n "$P" ] && ./cgui axpressin "$P" "AXDialog" "Cancel" | tee -a "$OUT/probe5.log"; sleep 5; shot "r5_D_after_cancel"; row "cancel" "$P"

L "1E AXPress the 'Create New Apple Account' button? no - instead: leave sheet, focus main window (no dismissal)"
fresh; sheet
[ -n "$P" ] && ./cgui key "x" >/dev/null 2>&1; sleep 3; shot "r5_E_after_focus_steal"; row "no_dismiss" "$P"

L "1F AppleScript 'close window 1' via System Events (AX-level close)"
fresh; sheet
[ -n "$P" ] && run osascript -e 'tell application "System Events" to tell process "Messages" to click button 1 of window 1'; sleep 4; shot "r5_F_after_button1"; row "button1" "$P"

L "2. Sign In button enabled-state before/after axfillin (dummy value, never submitted)"
fresh; sheet
if [ -n "$P" ]; then
  ./cgui axdump "$P" 10 > "$OUT/w_axdump_before_fill.txt" 2>&1
  echo "--- before fill: Sign In line ---" | tee -a "$OUT/probe5.log"
  grep -E 'title=\[Sign In\]' "$OUT/w_axdump_before_fill.txt" | head -2 | tee -a "$OUT/probe5.log"
  ./cgui axfillin "$P" "AXDialog" "probe-dummy@example.invalid" | tee -a "$OUT/probe5.log"
  sleep 2
  ./cgui axdump "$P" 10 > "$OUT/w_axdump_after_fill.txt" 2>&1
  echo "--- after fill: Sign In line ---" | tee -a "$OUT/probe5.log"
  grep -E 'title=\[Sign In\]' "$OUT/w_axdump_after_fill.txt" | head -2 | tee -a "$OUT/probe5.log"
  grep -E 'role=AXTextField.*id=\[_NS:76\]' "$OUT/w_axdump_after_fill.txt" | head -2 | tee -a "$OUT/probe5.log"
  shot "r5_G_after_fill"
fi

L "3. compose reachability while SIGNED OUT: open sms://open -> messageBodyField?"
killmsg; open -a Messages; sleep 9; P=$(pidof_msg); echo "pid=${P:-none}" | tee -a "$OUT/probe5.log"
# dismiss the sign-in sheet is unnecessary: just open the URL which brings up the compose window
run open "sms://open?address=+19496788958&body=PROBE_MARKER_i102896_DO_NOT_SEND"
sleep 8
shot "r5_H_compose_after_sms_open"
[ -n "$P" ] && { ./cgui axwinls "$P" > "$OUT/w_axwinls_compose.txt" 2>&1; cat "$OUT/w_axwinls_compose.txt" | tee -a "$OUT/probe5.log"; }
[ -n "$P" ] && { ./cgui axdump "$P" 14 > "$OUT/w_axdump_compose.txt" 2>&1;
  echo "bodyfield_hits=$(grep -c messageBodyField "$OUT/w_axdump_compose.txt")" | tee -a "$OUT/probe5.log"
  grep 'messageBodyField' "$OUT/w_axdump_compose.txt" | head -3 | tee -a "$OUT/probe5.log"
  ./cgui axfind "$P" "messagebodyfield" > "$OUT/w_axfind_body.txt" 2>&1; head -4 "$OUT/w_axfind_body.txt" | tee -a "$OUT/probe5.log"
  echo "--- body field coordinates (needed for axfocus/click) ---" | tee -a "$OUT/probe5.log"
  ./cgui axset "$P" "messagebodyfield" "PROBE_MARKER_i102896_DO_NOT_SEND" | tee -a "$OUT/probe5.log"
}
sleep 1; shot "r5_I_compose_field_set"

L "4. two-stage gate result under signed-out condition"
run python3 messages_login_send.py stage --outdir "$OUT/stage" --type-text "PROBE_MARKER_i102896_DO_NOT_SEND"
python3 - "$OUT/stage/stage.json" <<'PY' | tee -a "$OUT/probe5.log"
import json,sys
d=json.load(open(sys.argv[1]))
print('STAGE=',d.get('stage'),'signed_in=',d.get('signed_in'),'nothing_sent=',d.get('nothing_sent'))
print('min_input=',json.dumps(d.get('min_input'),ensure_ascii=False)[:400])
print('compose_steps=',json.dumps({k:v for k,v in (d.get('steps') or {}).items() if k in ('axfind_body','axset_body','compose_url','windows_after_open')},ensure_ascii=False)[:600])
PY

L "5. chat.db (must stay 0 rows: nothing sent)"
{ sqlite3 -readonly ~/Library/Messages/chat.db "select count(*) from message" 2>&1;
  sqlite3 -readonly ~/Library/Messages/chat.db "select count(*) from handle" 2>&1; } | tee -a "$OUT/probe5.log"
alive "$P" | tee -a "$OUT/probe5.log"
L "DONE5"
