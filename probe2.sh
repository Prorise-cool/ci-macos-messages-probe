#!/bin/bash
# round 2: pin down AX/System Events UI-scripting channel, sign-in sheet structure,
# compose-field targeting, and smoke-test messages_login_send.py. Sends nothing.
set -u
OUT="${OUT:-$PWD/out2}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/probe2.log"; }
R(){ echo "--- \$ $*" | tee -a "$OUT/probe2.log"; }
run(){ R "$@"; "$@" 2>&1 | sed 's/\r//' | head -120 | tee -a "$OUT/probe2.log"; }
osa(){ R "osascript($2)"; local n="$1"; shift; /usr/bin/time -p osascript "$@" 2>&1 | tail -25 | tee -a "$OUT/$n.osa.txt" | head -30 | tee -a "$OUT/probe2.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^(orig|BEST)' "$OUT/$n.ocr.txt" | head -4 | tee -a "$OUT/probe2.log"; fi; }
mpid(){ ./cgui list | grep -i 'owner=Messages' | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/'; }

L "0. build check"
ls -l cgui ocr 2>&1 | tee -a "$OUT/probe2.log"

L "1. launch + compose (no send)"
open -a Messages; sleep 6
shot "r2_00_launch"
R "open sms://open"; open "sms://open?address=+19496788958&body=PROBE_BODY_MARKER_i102837"; sleep 7
./cgui list | tee -a "$OUT/probe2.log"
shot "r2_01_compose_opened"
echo "MPID=$(mpid)" | tee -a "$OUT/probe2.log"

L "2. AX dump (AX API) of Messages"
P=$(mpid); echo "pid=$P"
if [ -n "$P" ]; then ./cgui axdump "$P" 8 > "$OUT/r2_ax_messages.txt" 2>&1; wc -l "$OUT/r2_ax_messages.txt" | tee -a "$OUT/probe2.log";
  grep -n -i -E 'AXButton|AXTextField|AXTextArea|AXSheet|Sign|Cancel|To:|placeholder' "$OUT/r2_ax_messages.txt" | head -40 | tee -a "$OUT/probe2.log"; fi

L "3. System Events UI-scripting recursive dump (window 1)"
osa "sysevents_dump" -e '
global accum
set accum to ""
on walk(el, depth)
  set line to ""
  try
    set line to line & "role=" & (role of el)
  end try
  try
    set line to line & " sub=" & (subrole of el)
  end try
  try
    set line to line & " title=[" & (title of el) & "]"
  end try
  try
    set line to line & " desc=[" & (description of el) & "]"
  end try
  try
    set line to line & " val=[" & (value of el as text) & "]"
  end try
  try
    set line to line & " pos=" & (position of el as text) & " size=" & (size of el as text)
  end try
  set accum to accum & line & linefeed
  if depth < 5 then
    try
      repeat with c in (UI elements of el)
        walk(c, depth + 1)
      end repeat
    end try
  end if
end walk
tell application "System Events" to tell process "Messages"
  try
    walk(window 1, 0)
  on error e
    set accum to "ERR " & e
  end try
end tell
return accum'
grep -i -E 'AXButton|Sign|Cancel|text field|text area|To:' "$OUT/sysevents_dump.osa.txt" | head -30 | tee -a "$OUT/probe2.log"

L "4. windows via System Events + names of buttons/sheets"
osa "se_windows" -e 'tell application "System Events" to tell process "Messages" to return {name of every window, (title of every button of window 1)}'
osa "se_sheets" -e 'tell application "System Events" to tell process "Messages" to return {count of sheets of window 1, description of every sheet of window 1}'

L "5. click Sign In (System Events, by name) -> dump sign-in sheet -> cancel"
osa "se_clicksignin" -e 'tell application "System Events" to tell process "Messages"
 try
   click button "Sign In" of window 1
   return "clicked-by-name"
 on error e1
   try
     click button "Sign in" of window 1
     return "clicked-by-name-lower"
   on error e2
     return "ERR " & e1 & " | " & e2
   end try
 end try
end tell'
sleep 5
./cgui list | tee -a "$OUT/probe2.log"
shot "r2_02_signin_sheet"
P=$(mpid); [ -n "$P" ] && ./cgui axdump "$P" 8 > "$OUT/r2_ax_signin.txt" 2>&1 && wc -l "$OUT/r2_ax_signin.txt" | tee -a "$OUT/probe2.log"
grep -i -n -E 'AXTextField|AXButton|AXSheet|Apple|password|Sign|Cancel|identifier' "$OUT/r2_ax_signin.txt" | head -40 | tee -a "$OUT/probe2.log"
osa "se_signin_sheet_dump" -e 'tell application "System Events" to tell process "Messages"
 try
   set w to window 1
   return {(name of w), (count of buttons of w), (description of every button of w), (count of text fields of w), (description of every text field of w), (value of every text field of w)}
 on error e
   return "ERR " & e
 end try
end tell'

L "6. cancel sheet / close compose (no send)"
osa "se_cancel" -e 'tell application "System Events" to tell process "Messages"
 try
   click button "Cancel" of window 1
   return "cancelled"
 on error e
   return "ERR " & e
 end try
end tell'
osa "se_esc" -e 'tell application "System Events" to key code 53'
sleep 2; shot "r2_03_after_cancel"

L "7. compose-field targeting: click center of message area then type marker"
osa "se_focus" -e 'tell application "System Events" to tell process "Messages"
 try
   set w to window 1
   set tg to text area 1 of w
   set {x, y} to position of tg
   set {ww, hh} to size of tg
   return {x, y, ww, hh}
 on error e
   return "ERR " & e
 end try
end tell'
run ./cgui key "MARKER_IN_BODY_i102837"
sleep 2; shot "r2_04_typed_body"

L "8. deliverable smoke test (messages_login_send.py)"
cp messages_login_send.py "$OUT/" 2>/dev/null || true
run python3 messages_login_send.py status --outdir "$OUT/msgprobe"
run python3 messages_login_send.py read --limit 5 --outdir "$OUT/msgprobe"
run python3 messages_login_send.py probe --outdir "$OUT/msgprobe"
ls -l "$OUT/msgprobe" | tee -a "$OUT/probe2.log"

L "9. account-query AppleEvent matrix (post-AX, 8s timeouts)"
osa "ae_after" -e 'with timeout of 8 seconds
tell application "Messages" to get name of every service
end timeout'
osa "ae_accounts_after" -e 'with timeout of 8 seconds
tell application "Messages" to get name of every account
end timeout'
osa "ae_version_after" -e 'tell application "Messages" to get version'

L "10. chat.db after interactions"
{ sqlite3 -readonly ~/Library/Messages/chat.db "select count(*) from message" 2>&1;
  sqlite3 -readonly ~/Library/Messages/chat.db "select * from sqlite_master where name='handle'" 2>&1 | head -3; } | tee -a "$OUT/probe2.log"

L "DONE2"
