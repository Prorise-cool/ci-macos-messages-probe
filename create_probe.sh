#!/bin/bash
# round 6: press the NATIVE "Create New Apple Account" button in Messages' sign-in sheet
# (defect in the parallel worker: it greped by title with a curly apostrophe / title IS the label),
# then dump exactly what the native creation surface is. SENDS NOTHING, submits nothing.
set -u
OUT="${OUT:-$PWD/out6}"; mkdir -p "$OUT"
L(){ echo "=== $* ===" | tee -a "$OUT/c6.log"; }
R(){ echo "--- \$ $*" | tee -a "$OUT/c6.log"; }
run(){ R "$@"; "$@" 2>&1 | sed 's/\r//' | head -200 | tee -a "$OUT/c6.log"; }
shot(){ local n="$1"; screencapture -x "$OUT/$n.png" >/dev/null 2>&1; if [ -x ./ocr ]; then ./ocr "$OUT/$n.png" > "$OUT/$n.ocr.txt" 2>&1; grep -h -E '^BEST' "$OUT/$n.ocr.txt" | head -1 | tee -a "$OUT/c6.log"; fi; }
pidof_msg(){ pgrep -x Messages | head -1; }
alive(){ local p="$1"; if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "ALIVE pid=$p"; else echo "DEAD pid=${p:-none}"; fi; }
killmsg(){ pkill -x Messages 2>/dev/null; sleep 2; pkill -9 -x Messages 2>/dev/null; sleep 1; }
allwin(){ echo "--- all windows ---" | tee -a "$OUT/c6.log"; ./cgui list 2>&1 | tee -a "$OUT/allwin_$1.txt" | head -25; }
procwatch(){ ps -Ao pid,comm | grep -E 'AKAuthorization|Safari|Messages|appleaccountd|SetupAssistant|AuthKit|akd' | grep -v grep | head -20; }

L "0. build check"
ls -l cgui ocr | tee -a "$OUT/c6.log"
echo "src_AXValueGetValue=$(grep -c AXValueGetValue cgui.swift) has_axpressname=$(grep -c axpressname cgui.swift) has_axformdump=$(grep -c axformdump cgui.swift)" | tee -a "$OUT/c6.log"

L "1. baseline: pid resolution via NSWorkspace (CGWindowList is unreliable here)"
killmsg; open -a Messages; sleep 9
./cgui axpid Messages | tee -a "$OUT/c6.log"
P=$(./cgui axpid Messages | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/')
echo "MPID=$P $(alive "$P")" | tee -a "$OUT/c6.log"
[ -n "$P" ] && ./cgui axwinls "$P" | tee -a "$OUT/c6.log"
[ -n "$P" ] && ./cgui axdump "$P" 10 > "$OUT/sheet_before.txt" 2>&1
echo "sheet_before lines=$(wc -l < "$OUT/sheet_before.txt" 2>/dev/null || echo 0)" | tee -a "$OUT/c6.log"
grep -n -E 'Create New Apple|Sign In|Cancel|Forgot' "$OUT/sheet_before.txt" 2>/dev/null | head -8 | tee -a "$OUT/c6.log"
shot "r6_00_sheet"

L "2. PRESS 'Create New Apple Account' by exact normalized title"
[ -n "$P" ] && ./cgui axpressname "$P" "Create New Apple Account" | tee -a "$OUT/c6.log"
sleep 8
shot "r6_01_after_create_press"
echo "MSG_ALIVE_AFTER_CREATE=$(alive "$P")" | tee -a "$OUT/c6.log"
allwin "after_create"
echo "--- process watch ---" | tee -a "$OUT/c6.log"; procwatch | tee -a "$OUT/c6.log"

L "3. dump every window of Messages + any new app (the creation UI may be a separate process/window)"
[ -n "$P" ] && ./cgui axwinls "$P" | tee -a "$OUT/c6.log"
[ -n "$P" ] && { ./cgui axdump "$P" 12 > "$OUT/after_create_full.txt" 2>&1; echo "after_create lines=$(wc -l < "$OUT/after_create_full.txt")" | tee -a "$OUT/c6.log"; }
echo "--- form-ish elements (dialog/sheet subtree) ---" | tee -a "$OUT/c6.log"
[ -n "$P" ] && ./cgui axformdump "$P" | tee -a "$OUT/c6.log"
echo "--- editable element inventory (name/birthday/email/password/phone) ---" | tee -a "$OUT/c6.log"
[ -n "$P" ] && ./cgui axfilln "$P" 0 "__PROBE_LIST_ONLY__" 2>&1 | head -40 | tee -a "$OUT/c6.log"
for nm in Safari "com.apple.Safari" "Setup Assistant" "System Settings"; do
  WP=$(./cgui axpid "$nm" 2>/dev/null | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/')
  [ -n "${WP:-}" ] && { echo "--- app=$nm pid=$WP windows ---" | tee -a "$OUT/c6.log"; ./cgui axwinls "$WP" | tee -a "$OUT/c6.log"; }
done

L "4. what did the sheet turn into? (static text inventory = the actual questions asked)"
[ -n "$P" ] && grep -E 'AXStaticText' "$OUT/after_create_full.txt" | head -40 | tee -a "$OUT/c6.log"
[ -n "$P" ] && grep -E 'AXButton|AXTextField|AXSecureTextField|AXCheckBox|AXPopUpButton|AXLink|AXWebArea' "$OUT/after_create_full.txt" | head -40 | tee -a "$OUT/c6.log"

L "5. Apple prefs (nothing created?)"
defaults read MobileMeAccounts 2>&1 | head -4 | tee -a "$OUT/mobileme.txt"
dscl . -list /Users 2>/dev/null | tail -5 | tee -a "$OUT/dscl_users.txt"
L "DONE6"
