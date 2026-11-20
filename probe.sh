#!/bin/bash
# Messages.app automation probe — read-only local, sends nothing (never presses Return)
set -u
OUT="${OUT:-$PWD/out}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/probe.log"; }
R(){ echo "--- \$ $*" | tee -a "$OUT/probe.log"; }
run(){ R "$@"; "$@" 2>&1 | sed 's/\r//' | tee -a "$OUT/probe.log" | head -200; }
osa(){ R "osascript: $1"; /usr/bin/time -p osascript -e "$1" 2>&1 | tail -20 | tee -a "$OUT/probe.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" 2>&1 | tee -a "$OUT/probe.log"; ls -l "$OUT/$n.png" 2>/dev/null | tee -a "$OUT/probe.log"; [ -x ./ocr ] && ./ocr "$OUT/$n.png" 2>&1 | tee -a "$OUT/$n.ocr.txt" | head -8; }

L "A. session / privilege / SIP"
{ who; id; echo "SESSION=$SESSIONNAME"; sw_vers; uname -m; sysctl -n hw.model;
  scutil <<< "show State:/Users/ConsoleUser" ;
  launchctl print gui/$(id -u) 2>&1 | head -3 ;
  csrutil status 2>&1;
} 2>&1 | tee -a "$OUT/probe.log"

L "B. TCC state (readability + existing rows)"
{ ls -ld ~/Library/Application\ Support/com.apple.TCC 2>&1;
  ls -l ~/Library/Application\ Support/com.apple.TCC/TCC.db 2>&1;
  sqlite3 -readonly ~/Library/Application\ Support/com.apple.TCC/TCC.db "select service, client, client_type, auth_value, auth_reason from access;" 2>&1 | head -40;
  echo "--system--";
  sudo -n sqlite3 -readonly /Library/Application\ Support/com.apple.TCC/TCC.db "select service, client, client_type, auth_value from access;" 2>&1 | head -40;
} 2>&1 | tee -a "$OUT/probe.log"

L "C. cgui probe + window list BEFORE Messages"
run ./cgui ax; run ./cgui list; shot "01_before"

L "D. launch Messages"
run open -a Messages; sleep 8
run pgrep -lf Messages
run pgrep -lf imagent
run lsappinfo list | grep -i -E 'Messages|imagent' | head
run ./cgui list
shot "02_after_launch"

L "E. AppleEvent timing matrix (fast-fail 10s)"
osa 'tell application "Messages" to get version'
osa 'tell application "Messages" to get name'
osa 'with timeout of 10 seconds
tell application "Messages" to get name of every service
end timeout'
osa 'with timeout of 10 seconds
tell application "Messages" to get name of every account
end timeout'
osa 'with timeout of 10 seconds
tell application "Messages" to get properties
end timeout'
osa 'with timeout of 10 seconds
tell application "Messages" to get count of every chat
end timeout'
osa 'tell application "Messages" to activate'
osa 'tell application "Messages" to launch'
osa 'with timeout of 10 seconds
tell application "Messages" to get id of application'
run lsappinfo info -only pid,bundleid,ASN -app Messages

L "F. System Events / UI scripting matrix"
osa 'tell application "System Events" to get UI elements enabled'
osa 'with timeout of 10 seconds
tell application "System Events" to get name of every process whose background only is false
end timeout'
osa 'tell application "System Events" to keystroke "a"'
osa 'tell application "System Events" to key code 53'
osa 'tell application "System Events" to click at {10,10}'
shot "03_after_sysevents"

L "G. chat.db readability / schema"
{ sqlite3 -readonly ~/Library/Messages/chat.db "select name from sqlite_master where type='table' order by 1;" 2>&1 | tr '\n' ' '; echo;
  sqlite3 -readonly ~/Library/Messages/chat.db "select count(*) from message; select count(*) from handle; select count(*) from chat;" 2>&1;
  sqlite3 -readonly ~/Library/Messages/chat.db ".schema message" 2>&1 | head -5;
  ls -l ~/Library/Messages/chat.db* 2>&1;
} 2>&1 | tee -a "$OUT/probe.log"

L "H. shortcuts cli / cliclick availability"
run which shortcuts; true
run which cliclick

L "J. compose window via URL scheme (NO send: we never press Return)"
run open "sms://open?address=+19496788958&body=PROBE_ONLY_NOT_SENT"
sleep 6; run ./cgui list; shot "05_compose"
run ./cgui key "TYPED_MARKER_NEVER_SENT"
sleep 2; shot "06_compose_typed"
run ./cgui list

L "K. Messages log tail (no account)"
{ log show --last 3m --style compact --predicate 'process == "Messages" OR process == "imagent"' 2>/dev/null | grep -i -E 'error|timeout|AppleEvent|script|account|sign' | tail -25; } 2>&1 | tee -a "$OUT/probe.log"

L "DONE"
