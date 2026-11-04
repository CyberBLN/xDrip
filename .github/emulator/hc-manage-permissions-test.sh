#!/bin/bash
# Emulator test for the Health Connect "Manage permissions" preference.
# Installs the APK, enables Health Connect in the preferences, opens
# Settings > Inter-app settings > Google Health Connect > Manage permissions
# and records which screen opens, screenshots, the UI tree and the log.
#
# Usage: hc-manage-permissions-test.sh <apk> <output dir> [expect-health-connect]
#
# Exit codes: 0 = test ran (and, with expect-health-connect, Health Connect opened)
#             1 = Health Connect expected but not opened
#             2 = the test itself failed (setup or navigation), result is not meaningful
set -u
APK=$1
OUT=$2
EXPECT=${3:-}
PKG=com.eveningoutpost.dexdrip
HC_PKG=com.google.android.healthconnect.controller
PREFS=/data/data/$PKG/shared_prefs/${PKG}_preferences.xml
mkdir -p "$OUT"
# adb shell must never wait for input from the runner
exec </dev/null

log() { echo "[$(date +%T)] $*" | tee -a "$OUT/steps.txt"; }

summary() {
    log "RESULT: $*"
    echo "$*" > "$OUT/result.txt"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '| APK | Android | Result |\n|---|---|---|\n| %s | API %s | %s |\n' "$(basename "$APK")" "${API:-?}" "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

abort() {
    summary "TEST ERROR: $*"
    adb exec-out screencap -p > "$OUT/error.png" 2>/dev/null
    adb logcat -d > "$OUT/logcat-full.txt" 2>/dev/null
    exit 2
}

# Dump the UI tree to $OUT/ui-last.xml; retries because uiautomator fails while the UI is busy.
dump_ui() {
    local i
    for ((i = 0; i < 3; i++)); do
        if timeout 60 adb shell uiautomator dump /sdcard/ui.xml 2>&1 | grep -q 'dumped to'; then
            adb shell cat /sdcard/ui.xml > "$OUT/ui-last.xml"
            return 0
        fi
        sleep 2
    done
    return 1
}

# Print "x y" of the centre of the first node whose text matches exactly.
find_text() {
    python3 - "$OUT/ui-last.xml" "$1" <<'EOF'
import sys, re, xml.etree.ElementTree as ET
try:
    nodes = ET.parse(sys.argv[1]).iter('node')
except ET.ParseError:
    sys.exit()
for n in nodes:
    if n.get('text') == sys.argv[2]:
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', n.get('bounds')))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
EOF
}

# A slow emulator often shows "<app> isn't responding". The launcher is not needed for the
# test, so close it; for any other app answer with "Wait".
dismiss_anr() {
    local title button pos
    grep -q "isn&apos;t responding\|isn't responding" "$OUT/ui-last.xml" 2>/dev/null || return 1
    title=$(grep -o 'text="[^"]*responding"' "$OUT/ui-last.xml" | head -1)
    case "$title" in
        *Launcher*) button="Close app" ;;
        *) button="Wait" ;;
    esac
    pos=$(find_text "$button")
    [ -n "$pos" ] || return 1
    log "ANR dialog: $title, tapping $button"
    adb shell input tap $pos
    sleep 3
    return 0
}

# Tap the first element whose text matches; dismiss ANR dialogs, scroll down and retry if needed.
tap_text() {
    local text=$1 tries=${2:-8} i=0 anr=0 pos
    while ((i < tries)); do
        dump_ui || { log "uiautomator dump failed"; ((i++)); continue; }
        # Dismissing an ANR dialog does not count as a try (but at most 10 of them).
        if ((anr < 10)) && dismiss_anr; then ((anr++)); continue; fi
        ((i++))
        pos=$(find_text "$text")
        if [ -n "$pos" ]; then
            log "tap '$text' at $pos"
            adb shell input tap $pos
            sleep 3
            return 0
        fi
        adb shell input swipe 540 1700 540 700 300
        sleep 1
    done
    cp "$OUT/ui-last.xml" "$OUT/ui-not-found.xml" 2>/dev/null
    return 1
}

resumed() {
    adb shell dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity' | head -1 |
        grep -oE '[a-z0-9_.]+/[A-Za-z0-9_.$]+' | head -1
}

# Start the preferences and wait until they are in front (they are not exported, so this needs root).
open_preferences() {
    local i
    for ((i = 0; i < 3; i++)); do
        timeout 60 adb shell am start -W -n $PKG/.utils.Preferences >/dev/null
        sleep 3
        dump_ui && dismiss_anr
        [[ "$(resumed)" == $PKG/* ]] && return 0
        log "preferences not in front (resumed: $(resumed)), retrying"
        sleep 5
    done
    return 1
}

adb root >/dev/null; sleep 3; adb wait-for-device
API=$(adb shell getprop ro.build.version.sdk | tr -d '\r')
log "Android $(adb shell getprop ro.build.version.release | tr -d '\r') / API $API"
log "Health Connect: $(adb shell pm list packages | grep -iE 'healthconnect|healthdata' | tr -d '\r' | tr '\n' ' ')"

# Let the system settle, then stop the launcher: on a cold emulator (seen on API 34) it keeps
# reporting ANRs, and the test only needs xDrip+ and Health Connect in front.
sleep 15
dump_ui && dismiss_anr
adb shell am force-stop com.google.android.apps.nexuslauncher

adb install -r -g "$APK" | tee -a "$OUT/steps.txt" | grep -q Success || abort "APK installation failed"
adb logcat -c

# Open the preferences once so that the preferences file exists, then enable Health Connect
# directly in the file (switching it on in the UI would start the permission request flow).
open_preferences || abort "preferences did not open (first start)"
adb shell am force-stop $PKG
adb shell "test -f $PREFS || printf '<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\" ?>\n<map>\n</map>\n' > $PREFS"
adb shell "o=\$(stat -c %u:%g /data/data/$PKG); sed -i -e '/name=\"health_connect_enable\"/d' -e 's#</map>#    <boolean name=\"health_connect_enable\" value=\"true\" />\n    <boolean name=\"warning_agreed_to\" value=\"true\" />\n    <boolean name=\"I_understand\" value=\"true\" />\n</map>#' $PREFS; chown \$o $PREFS; chmod 660 $PREFS; restorecon $PREFS"
adb shell "grep -E 'health_connect|agreed' $PREFS" | tee -a "$OUT/steps.txt" |
    grep -q 'name="health_connect_enable" value="true"' || abort "could not enable Health Connect in the preferences"

open_preferences || abort "preferences did not open"
tap_text "Inter-app settings" 15 || abort "'Inter-app settings' not found"
tap_text "Google Health Connect" 10 || abort "'Google Health Connect' not found"
adb exec-out screencap -p > "$OUT/1-health-connect-settings.png"
tap_text "Manage permissions" 6 || abort "'Manage permissions' not found"
sleep 5

TOP=$(resumed)
log "resumed activity after tap: $TOP"
adb exec-out screencap -p > "$OUT/2-after-manage-permissions.png"
dump_ui && cp "$OUT/ui-last.xml" "$OUT/ui-after.xml"
adb logcat -d > "$OUT/logcat-full.txt"
grep -E 'HealthGamut|SecurityException|GRANT_RUNTIME_PERMISSIONS|ActivityNotFound|ActivityTaskManager: START|AndroidRuntime: (FATAL|E )' \
    "$OUT/logcat-full.txt" > "$OUT/logcat-relevant.txt"
log "relevant log lines:"
grep -E 'HealthGamut|healthconnect' "$OUT/logcat-relevant.txt" | tee -a "$OUT/steps.txt"

DENIED=""
grep -q 'requires android.permission.GRANT_RUNTIME_PERMISSIONS' "$OUT/logcat-relevant.txt" && DENIED=" (MANAGE_HEALTH_PERMISSIONS refused: GRANT_RUNTIME_PERMISSIONS)"
grep -q 'FATAL EXCEPTION' "$OUT/logcat-full.txt" && grep -A3 'FATAL EXCEPTION' "$OUT/logcat-full.txt" | grep -q "$PKG" && DENIED="$DENIED, xDrip+ CRASHED"

case "$TOP" in
    $HC_PKG/*)
        summary "Health Connect opened: ${TOP#*/}$DENIED"
        exit 0 ;;
    $PKG/*)
        summary "nothing opened, xDrip+ still in front$DENIED"
        [ "$EXPECT" = expect-health-connect ] && exit 1
        exit 0 ;;
    *)
        summary "unexpected screen in front: $TOP$DENIED"
        [ "$EXPECT" = expect-health-connect ] && exit 1
        exit 0 ;;
esac
