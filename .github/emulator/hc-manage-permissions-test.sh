#!/bin/bash
# Emulator test for the Health Connect "Manage permissions" preference.
# Installs the APK, enables Health Connect in the preferences, opens
# Settings > Inter-app settings > Google Health Connect > Manage permissions
# and records which screen opens, a screenshot, the UI tree and the log.
# Usage: hc-manage-permissions-test.sh <apk> <output dir>
set -u
APK=$1
OUT=$2
PKG=com.eveningoutpost.dexdrip
PREFS=/data/data/$PKG/shared_prefs/${PKG}_preferences.xml
mkdir -p "$OUT"

log() { echo "[$(date +%T)] $*" | tee -a "$OUT/steps.txt"; }

# Tap the first element whose text matches; scroll down and retry if it is not visible.
tap_text() {
    local text=$1 tries=${2:-8} i bounds
    for ((i = 0; i < tries; i++)); do
        adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
        adb shell cat /sdcard/ui.xml > "$OUT/ui-last.xml"
        bounds=$(python3 - "$OUT/ui-last.xml" "$text" <<'EOF'
import sys, re, xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).iter('node'):
    if n.get('text') == sys.argv[2]:
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', n.get('bounds')))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
EOF
)
        if [ -n "$bounds" ]; then
            log "tap '$text' at $bounds"
            adb shell input tap $bounds
            sleep 3
            return 0
        fi
        adb shell input swipe 540 1700 540 700 300
        sleep 1
    done
    log "NOT FOUND: '$text'"
    return 1
}

resumed() { adb shell dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity' | head -1 | sed 's/^ *//'; }

adb root >/dev/null; sleep 3; adb wait-for-device
log "Android $(adb shell getprop ro.build.version.release) / API $(adb shell getprop ro.build.version.sdk)"
log "Health Connect: $(adb shell pm list packages | grep -iE 'healthconnect|healthdata' | tr '\n' ' ')"

adb install -r -g "$APK" | tee -a "$OUT/steps.txt"
adb logcat -c

# Open the preferences once so that the preferences file exists, then enable Health Connect
# directly in the file (switching it on in the UI would start the permission request flow).
adb shell am start -W -n $PKG/.utils.Preferences >/dev/null; sleep 5
adb shell am force-stop $PKG
adb shell "test -f $PREFS || printf '<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\" ?>\n<map>\n</map>\n' > $PREFS"
adb shell "o=\$(stat -c %u:%g /data/data/$PKG); sed -i -e '/name=\"health_connect_enable\"/d' -e 's#</map>#    <boolean name=\"health_connect_enable\" value=\"true\" />\n    <boolean name=\"warning_agreed_to\" value=\"true\" />\n    <boolean name=\"I_understand\" value=\"true\" />\n</map>#' $PREFS; chown \$o $PREFS; chmod 660 $PREFS; restorecon $PREFS"
adb shell grep -E 'health_connect|agreed' $PREFS | tee -a "$OUT/steps.txt"

adb shell am start -W -n $PKG/.utils.Preferences >/dev/null; sleep 5
tap_text "Inter-app settings" 15 &&
    tap_text "Google Health Connect" 10 &&
    adb exec-out screencap -p > "$OUT/1-health-connect-settings.png" &&
    tap_text "Manage permissions" 6
sleep 5

log "resumed activity after tap: $(resumed)"
adb exec-out screencap -p > "$OUT/2-after-manage-permissions.png"
adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb shell cat /sdcard/ui.xml > "$OUT/ui-after.xml"
adb logcat -d > "$OUT/logcat-full.txt"
grep -E 'HealthGamut|SecurityException|GRANT_RUNTIME_PERMISSIONS|ActivityNotFound|ActivityTaskManager: START|AndroidRuntime' "$OUT/logcat-full.txt" > "$OUT/logcat-relevant.txt"
log "relevant log lines:"
tee -a "$OUT/steps.txt" < "$OUT/logcat-relevant.txt"
exit 0
