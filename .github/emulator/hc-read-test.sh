#!/bin/bash
# Emulator test for reading steps and heart rate from Health Connect.
# Writes test records with the hc-writer app (12 heart rate samples and one steps record
# per count), installs xDrip+, enables Health Connect receive, opens xDrip+ so that it does
# its initial Health Connect read, and counts the heart rate and steps rows in its database.
#
# Usage: hc-read-test.sh <xdrip apk> <writer apk> <output dir> <step counts> [expect-hr] [expect-steps]
#   step counts: comma separated, e.g. 100,120,150 or 100,0,150
#   expect-hr:    fail unless all 12 heart rate samples are stored
#   expect-steps: fail unless one steps row per steps record is stored
#
# Exit codes: 0 = test ran and the expectations are met
#             1 = an expectation is not met
#             2 = the test itself failed (setup), result is not meaningful
set -u
APK=$1
WRITER=$2
OUT=$3
STEPS=$4
shift 4
EXPECT=" $* "
PKG=com.eveningoutpost.dexdrip
WPKG=eu.kaischroeder.hcwriter
PREFS=/data/data/$PKG/shared_prefs/${PKG}_preferences.xml
HR_WRITTEN=12
STEPS_WRITTEN=$(echo "$STEPS" | tr ',' '\n' | grep -c .)
mkdir -p "$OUT"
exec </dev/null

log() { echo "[$(date +%T)] $*" | tee -a "$OUT/steps.txt"; }

summary() {
    log "RESULT: $*"
    echo "$*" > "$OUT/result.txt"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '| APK | Android | Steps written | Result |\n|---|---|---|---|\n| %s | API %s | %s | %s |\n' \
            "$(basename "$APK")" "${API:-?}" "$STEPS" "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

abort() {
    summary "TEST ERROR: $*"
    adb exec-out screencap -p > "$OUT/error.png" 2>/dev/null
    adb logcat -d > "$OUT/logcat-full.txt" 2>/dev/null
    exit 2
}

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

find_text() {
    python3 - "$OUT/ui-last.xml" "$1" <<'PY'
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
PY
}

# Close "<app> isn't responding" dialogs: the launcher with "Close app", anything else with "Wait".
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

resumed() {
    adb shell dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity' | head -1 |
        grep -oE '[a-z0-9_.]+/[A-Za-z0-9_.$]+' | head -1
}

# Start the preferences and wait until they are in front (not exported, so this needs root).
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

# Print "<heart rate rows> <steps rows>" from the xDrip+ database.
count_rows() {
    rm -rf "$OUT/db" && mkdir -p "$OUT/db"
    local f
    for f in $(adb shell ls /data/data/$PKG/databases/ | tr -d '\r' | grep '^DexDrip.db'); do
        adb pull "/data/data/$PKG/databases/$f" "$OUT/db/$f" >/dev/null
    done
    python3 - "$OUT/db/DexDrip.db" "$OUT/db-rows.txt" <<'PY'
import sys, sqlite3, datetime
db = sqlite3.connect(sys.argv[1])
counts = []
with open(sys.argv[2], 'w') as out:
    for table, value in (('HeartRate', 'bpm'), ('PebbleMovement', 'metric')):
        try:
            rows = db.execute(f'select timestamp, {value} from {table} order by timestamp').fetchall()
        except sqlite3.Error:
            rows = []
        counts.append(len(rows))
        out.write(f'{table}: {len(rows)} rows\n')
        for ts, v in rows:
            out.write(f'  {datetime.datetime.fromtimestamp(ts / 1000):%H:%M:%S} {v}\n')
print(*counts)
PY
}

adb root >/dev/null; sleep 3; adb wait-for-device
API=$(adb shell getprop ro.build.version.sdk | tr -d '\r')
log "Android $(adb shell getprop ro.build.version.release | tr -d '\r') / API $API"

# Let the system settle and stop the launcher (cold emulators keep reporting launcher ANRs).
sleep 15
dump_ui && dismiss_anr
adb shell am force-stop com.google.android.apps.nexuslauncher

# 1. Test records into Health Connect, before xDrip+ is installed, so its initial read sees them.
adb install -r -g "$WRITER" | tee -a "$OUT/steps.txt" | grep -q Success || abort "writer installation failed"
adb logcat -c
timeout 60 adb shell am start -W -n $WPKG/.MainActivity --es steps "$STEPS" >/dev/null
for ((i = 0; i < 30; i++)); do
    W=$(adb logcat -d -s HCWRITER:* | grep -E 'OK inserted|FAILED' | head -1)
    [ -n "$W" ] && break
    sleep 2
done
log "writer: ${W:-no result}"
[[ "$W" == *"OK inserted"* ]] || abort "could not write the test records: ${W:-no result}"

# 2. Install xDrip+ (-g also grants its Health Connect permissions) and enable Health Connect receive.
adb install -r -g "$APK" | tee -a "$OUT/steps.txt" | grep -q Success || abort "APK installation failed"
open_preferences || abort "preferences did not open (first start)"
adb shell am force-stop $PKG
adb shell "test -f $PREFS || printf '<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\" ?>\n<map>\n</map>\n' > $PREFS"
adb shell "o=\$(stat -c %u:%g /data/data/$PKG); sed -i -e '/name=\"health_connect_enable\"/d' -e '/name=\"health_connect_receive\"/d' -e 's#</map>#    <boolean name=\"health_connect_enable\" value=\"true\" />\n    <boolean name=\"health_connect_receive\" value=\"true\" />\n    <boolean name=\"warning_agreed_to\" value=\"true\" />\n    <boolean name=\"I_understand\" value=\"true\" />\n</map>#' $PREFS; chown \$o $PREFS; chmod 660 $PREFS; restorecon $PREFS"
adb shell "grep -E 'health_connect|agreed' $PREFS" | tee -a "$OUT/steps.txt" |
    grep -q 'name="health_connect_receive" value="true"' || abort "could not enable Health Connect receive"
adb logcat -c

# 3. Open xDrip+ and keep it in front (Health Connect only allows reads in the foreground) until
#    the initial read is done: it ends with the changes token or an error.
open_preferences || abort "preferences did not open"
for ((i = 0; i < 45; i++)); do
    adb logcat -d -s HealthGamut:* | grep -qE 'Changes token|Failed to read records|Failed to process records' && break
    sleep 2
done
sleep 10
adb logcat -d > "$OUT/logcat-full.txt"
grep -E 'HealthGamut|ReadReplyProcessor|StepCounter|AndroidRuntime' "$OUT/logcat-full.txt" > "$OUT/logcat-relevant.txt"
log "relevant log lines:"
grep -E 'HealthGamut' "$OUT/logcat-relevant.txt" | cut -c1-220 | tee -a "$OUT/steps.txt"
grep -qE 'HealthGamut' "$OUT/logcat-relevant.txt" || abort "xDrip+ did not read from Health Connect"
adb exec-out screencap -p > "$OUT/xdrip.png"
adb shell am force-stop $PKG

# 4. Count what xDrip+ stored.
read -r HR ST < <(count_rows) || abort "could not read the xDrip+ database"
cat "$OUT/db-rows.txt" >> "$OUT/steps.txt"
NOTE=""
grep -q 'count must not be less than 1' "$OUT/logcat-relevant.txt" && NOTE=" (read failed: count must not be less than 1)"
grep -A3 'FATAL EXCEPTION' "$OUT/logcat-full.txt" | grep -q "$PKG" && NOTE="$NOTE, xDrip+ CRASHED"
summary "heart rate $HR/$HR_WRITTEN, steps $ST/$STEPS_WRITTEN$NOTE"

RC=0
[[ "$EXPECT" == *" expect-hr "* ]] && [ "$HR" -ne "$HR_WRITTEN" ] && RC=1
[[ "$EXPECT" == *" expect-steps "* ]] && [ "$ST" -ne "$STEPS_WRITTEN" ] && RC=1
exit $RC
