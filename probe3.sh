#!/bin/bash
# round 3: (a) prove AXValue coordinate decoding works (old build printed pos=<__NSCFType>),
#          (b) find a way to dismiss the sign-in sheet that does NOT kill Messages,
#          (c) axset/axpress/axfocus on the sign-in sheet,
#          (d) locate messageBodyField in the compose window,
#          (e) two-stage gate "login state first, compose second" (messages_login_send.py stage).
# SENDS NOTHING. Never presses Return in a chat window.
set -u
OUT="${OUT:-$PWD/out3}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/probe3.log"; }
R(){ echo "--- \$ $*" | tee -a "$OUT/probe3.log"; }
run(){ R "$@"; "$@" 2>&1 | sed 's/\r//' | head -140 | tee -a "$OUT/probe3.log"; }
osa(){ local n="$1"; shift; R "osascript($n)"; /usr/bin/time -p osascript "$@" 2>&1 | tail -30 | tee -a "$OUT/$n.osa.txt" | head -20 | tee -a "$OUT/probe3.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^BEST' "$OUT/$n.ocr.txt" | head -2 | tee -a "$OUT/probe3.log"; fi; }
mpid(){ ./cgui list | grep -i 'owner=Messages' | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/'; }
alive(){ local p="$1"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "ALIVE pid=$p" || echo "DEAD pid=${p:-none}"; }

L "0. build check (cgui must contain AXValueGetValue decoding + axwinls)"
ls -l cgui ocr 2>&1 | tee -a "$OUT/probe3.log"
grep -c "AXValueGetValue" cgui.swift 2>/dev/null | sed 's/^/swift-AXValueGetValue-count=/' | tee -a "$OUT/probe3.log"

L "1. launch Messages, capture AX window list + full AX dump with DECODED coordinates"
open -a Messages; sleep 8
./cgui ax | tee -a "$OUT/probe3.log"
P=$(mpid); echo "MPID=$P" | tee -a "$OUT/probe3.log"
shot "r3_00_launch"
./cgui axwinls "$P" > "$OUT/r3_axwinls_launch.txt" 2>&1; cat "$OUT/r3_axwinls_launch.txt" | tee -a "$OUT/probe3.log"
./cgui axdump "$P" 10 > "$OUT/r3_axdump_launch.txt" 2>&1
echo "raw-typename-lines=$(grep -c '__NSCFType' "$OUT/r3_axdump_launch.txt")" | tee -a "$OUT/probe3.log"
echo "decoded-pos-lines=$(grep -c 'pos=[0-9-]' "$OUT/r3_axdump_launch.txt")" | tee -a "$OUT/probe3.log"
echo "--- first 12 decoded pos lines ---" | tee -a "$OUT/probe3.log"
grep 'pos=[0-9-]' "$OUT/r3_axdump_launch.txt" | head -12 | tee -a "$OUT/probe3.log"

L "2. axfind/axpress: open the sign-in sheet via AXPress on the Sign In button"
./cgui axfind "$P" "sign in" > "$OUT/r3_axfind_signin.txt" 2>&1
grep -E 'matches=|role=AXButton' "$OUT/r3_axfind_signin.txt" | head -8 | tee -a "$OUT/probe3.log"
./cgui axpress "$P" "Sign In" | tee -a "$OUT/probe3.log"
sleep 6
shot "r3_01_sheet"
./cgui axwinls "$P" > "$OUT/r3_axwinls_sheet.txt" 2>&1; cat "$OUT/r3_axwinls_sheet.txt" | tee -a "$OUT/probe3.log"
./cgui axdump "$P" 10 > "$OUT/r3_axdump_sheet.txt" 2>&1
echo "sheet-decoded-pos-lines=$(grep -c 'pos=[0-9-]' "$OUT/r3_axdump_sheet.txt")" | tee -a "$OUT/probe3.log"
grep -n -E 'AXTextField|AXSecureTextField|AXButton|AXSheet|AXDialog|Sign In|Cancel' "$OUT/r3_axdump_sheet.txt" | head -25 | tee -a "$OUT/probe3.log"

L "3. axset into the sign-in sheet field (dummy value, never submitted)"
./cgui axset "$P" "Email or Phone Number" "probe-dummy@example.invalid" | tee -a "$OUT/probe3.log"
./cgui axfillin "$P" "AXDialog" "probe-dummy2@example.invalid" | tee -a "$OUT/probe3.log"
sleep 1; shot "r3_02_sheet_filled"

L "4. closing-method matrix: which dismissal keeps Messages alive?"
echo "before-close: $(alive "$P")" | tee -a "$OUT/probe3.log"
# 4a ESC keycode
L "4a esc keycode 53"
./cgui keycode 53 | tee -a "$OUT/probe3.log"; sleep 3
shot "r3_03_after_esc"; echo "after-esc: $(alive "$P") windows=$(./cgui axwinls "$P" 2>&1 | head -1)" | tee -a "$OUT/probe3.log"
# if the dialog survived, 4b AXCloseButton on the dialog
L "4b AXCloseButton press (inside dialog) if still present"
./cgui axwinls "$P" > "$OUT/r3_axwinls_after_esc.txt" 2>&1; cat "$OUT/r3_axwinls_after_esc.txt" | tee -a "$OUT/probe3.log"
./cgui axpressin "$P" "AXDialog" "close button" | tee -a "$OUT/probe3.log"; sleep 3
shot "r3_04_after_closebtn"; echo "after-closebtn: $(alive "$P") windows=$(./cgui axwinls "$P" 2>&1 | head -1)" | tee -a "$OUT/probe3.log"
# 4c Cancel button LAST (known to kill)
L "4c Cancel button press (expected to quit Messages)"
./cgui axdump "$P" 10 > "$OUT/r3_axdump_pre_cancel.txt" 2>&1
./cgui axpressin "$P" "AXDialog" "Cancel" | tee -a "$OUT/probe3.log"; sleep 4
shot "r3_05_after_cancel"; echo "after-cancel: $(alive "$P")" | tee -a "$OUT/probe3.log"

L "5. relaunch and check compose reachability (messageBodyField) - draft only"
open -a Messages; sleep 8
P=$(mpid); echo "MPID2=$P" | tee -a "$OUT/probe3.log"
./cgui front Messages >/dev/null 2>&1; sleep 1
./cgui axdump "$P" 12 > "$OUT/r3_axdump_relaunch.txt" 2>&1
./cgui axfind "$P" "messagebodyfield" > "$OUT/r3_axfind_body.txt" 2>&1
grep -E 'matches=|email or phone|sign in' "$OUT/r3_axfind_body.txt" | head -5 | tee -a "$OUT/probe3.log"
grep -c 'messageBodyField' "$OUT/r3_axdump_relaunch.txt" | sed 's/^/messageBodyField-hits=/' | tee -a "$OUT/probe3.log"
grep 'messageBodyField' "$OUT/r3_axdump_relaunch.txt" | head -3 | tee -a "$OUT/probe3.log"

L "6. two-stage gate (messages_login_send.py stage) - login state first, compose second"
run python3 messages_login_send.py stage --outdir "$OUT/stage" --type-text "PROBE_MARKER_i102896_DO_NOT_SEND"
echo "stage.json:" | tee -a "$OUT/probe3.log"
python3 -c "import json;d=json.load(open('$OUT/stage/stage.json'));print('STAGE=',d.get('stage'),'signed_in=',d.get('signed_in'),'nothing_sent=',d.get('nothing_sent'))" 2>&1 | tee -a "$OUT/probe3.log"

L "7. chat.db snapshot (proves nothing was sent)"
{ sqlite3 -readonly ~/Library/Messages/chat.db "select count(*) from message" 2>&1;
  sqlite3 -readonly ~/Library/Messages/chat.db "select count(*) from handle" 2>&1; } | tee -a "$OUT/probe3.log"

alive "$P" | tee -a "$OUT/probe3.log"
L "DONE3"
