#!/usr/bin/env bash
#
# Marketing screenshots for BigTable.
#
# Builds the app (Debug) for the Simulator, opens each screen in screenshot mode (demo content,
# no iCloud or network, see BigTable/App/ScreenshotMode.swift) and saves:
#
#   screenshots/<device>/<appearance>/NN-<screen>.png   full size, for the App Store and press
#   ../bigtable-website/website/public/screens/<screen>.png and <screen>-dark.png
#                                                       resized, for the website (light and dark themes)
#
# Usage:
#   scripts/screenshots.sh                 every screen, light and dark
#   scripts/screenshots.sh plan grocery aipreview   just these screens
#   scripts/screenshots.sh --list-screens   the screen names, in order
#
# Options (environment variables):
#   DEVICE_TYPE="iPhone 17 Pro Max"   Simulator model. Default: one with the 6.9" screen App Store
#                                     Connect asks for (1320 × 2868), or else the biggest iPhone screen.
#   DEVICE_TYPE="iPad Pro 13-inch (M5)"
#                                     Any Simulator model works, iPads included.
#   APPEARANCES="light"               "light", "dark" or "light dark" (default).
#   ORIENTATIONS="portrait landscape" "portrait" (default), "landscape" or both. Landscape is
#                                     for iPads (the app is portrait only on iPhone) and saved in
#                                     <appearance>-landscape folders. It turns the Simulator
#                                     through its Device menu, which needs Accessibility access.
#   SHUTDOWN=1                        Shut the Simulator down when done.
#   SHOT_EVENTS=1                     Also print @@SHOT progress lines (Hearth Ship reads them).
#   SKIP_BUILD=1                      Reuse the last build.
#   WEB_WIDTH=720                     Width of the website copies, in pixels.
#   TEXT_SIZE=accessibility-extra-extra-extra-large
#                                     Capture at another text size, to check large-text layouts. Any
#                                     size the Simulator knows (extra-small … extra-extra-extra-large,
#                                     accessibility-medium … accessibility-extra-extra-extra-large).
#                                     Saved in a folder of its own; no website copies.
#
# Needs Xcode and its command line tools. Uses its own Simulator ("BigTable Screenshots"), so
# your other simulators and their data are untouched.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# MARK: This app

APP_NAME="BigTable"
PROJECT="$ROOT/BigTable.xcodeproj"
SCHEME="BigTable"
BUNDLE_ID="com.stephenwarren.bigtable"
PRODUCT="BigTable.app"
# Launch arguments that turn on screenshot mode; the screen name follows SCREEN_ARGUMENT.
MODE_ARGUMENT="-Screenshots"
SCREEN_ARGUMENT="-Screen"
# Where resized copies go for a website ("" for none): <screen>.png from light mode, and with
# WEB_DARK=1 also <screen>-dark.png from dark mode, for a site with a dark theme.
WEB="$ROOT/../bigtable-website/website/public/screens"
WEB_DARK="1"

# Screens in the order they're numbered, and how long each needs to settle (seconds).
ALL_SCREENS=(plan recipes recipe grocery aiplan aipreview community cook notifications profile)
settle_time() {
  case "$1" in
    recipe|aiplan|cook|notifications|profile) echo 5 ;; # pushed pages and sheets
    aipreview) echo 8 ;;                               # runs the planning animation first
    *) echo 4 ;;
  esac
}

# MARK: Setup

DERIVED="$ROOT/build/screenshots"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/$PRODUCT"
OUT="$ROOT/screenshots"
SIM_NAME="$APP_NAME Screenshots"
APPEARANCES="${APPEARANCES:-light dark}"
TEXT_SIZE="${TEXT_SIZE:-}"
WEB_WIDTH="${WEB_WIDTH:-720}"
ORIENTATIONS="${ORIENTATIONS:-portrait}"
# Turns the Simulator's landscape screenshots upright, when simctl saves them sideways
# (sips rotates clockwise by this many degrees). Only used when a capture comes out portrait.
LANDSCAPE_ROTATION="${LANDSCAPE_ROTATION:-270}"

if [[ "${1:-}" == "--list-screens" ]]; then printf '%s\n' "${ALL_SCREENS[@]}"; exit 0; fi
for orientation in $ORIENTATIONS; do
  [[ "$orientation" == portrait || "$orientation" == landscape ]] || { echo "Unknown orientation: $orientation (portrait or landscape)" >&2; exit 1; }
done

if [[ $# -gt 0 ]]; then SCREENS=("$@"); else SCREENS=("${ALL_SCREENS[@]}"); fi
for screen in "${SCREENS[@]}"; do
  [[ " ${ALL_SCREENS[*]} " == *" $screen "* ]] || { echo "Unknown screen: $screen (choose from: ${ALL_SCREENS[*]})" >&2; exit 1; }
done

log() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Progress lines for Hearth Ship (SHOT_EVENTS=1): @@SHOT<tab>event<tab>fields…
event() {
  [[ -n "${SHOT_EVENTS:-}" ]] || return 0
  local IFS=$'\t'
  printf '@@SHOT\t%s\n' "$*"
}

# MARK: Simulator

json() { xcrun simctl list "$1" -j; }

# Helpers in Python, written to files rather than inline: macOS's bash 3.2 misreads Python
# (comments, quotes, parentheses) inside $( ... ).
HELPERS="$(mktemp -d)"
UDID=""
ROTATED=""
SHUTDOWN_AFTER="${SHUTDOWN:-}"
cleanup() {
  trap '' TERM INT   # a second stop signal mustn't cut the cleanup short
  if [[ -n "$ROTATED" ]]; then rotate portrait || true; fi
  if [[ -n "$UDID" ]]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    if [[ -n "$SHUTDOWN_AFTER" ]]; then xcrun simctl shutdown "$UDID" 2>/dev/null || true; fi
  fi
  rm -rf "$HELPERS"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# Turns the Simulator window with this device (the one `open -a Simulator` just brought
# forward) to portrait or landscape, through the Simulator's Device menu. macOS asks once to
# let Hearth Ship (or Terminal) control the computer for this: System Settings › Privacy &
# Security › Accessibility.
rotate() {
  local item
  if [[ "$1" == landscape ]]; then
    [[ -z "$ROTATED" ]] || return 0
    item="Rotate Left"
  else
    [[ -n "$ROTATED" ]] || return 0
    item="Rotate Right"
  fi
  open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
  sleep 1
  if ! osascript \
      -e 'tell application "Simulator" to activate' \
      -e "tell application \"System Events\" to tell process \"Simulator\" to click menu item \"$item\" of menu \"Device\" of menu bar 1" \
      >/dev/null 2>&1; then
    echo "Couldn't turn the Simulator ($item). Allow control in System Settings › Privacy & Security › Accessibility, then try again." >&2
    return 1
  fi
  if [[ "$1" == landscape ]]; then ROTATED=1; else ROTATED=""; fi
  sleep 2   # the rotation animates
}

cat > "$HELPERS/pick.py" <<'PY'
import json, os, plistlib, re, sys

# Picks the Simulator runtime and model. Every installed iOS runtime is considered, newest first,
# because a runtime made for one new device (an iOS x.1 built only for a new model) may support
# nothing else. Choice: DEVICE_TYPE if given; otherwise a model with the 6.9-inch App Store screen
# (1320 x 2868) or the biggest tall iPhone screen, when Xcode reports sizes; otherwise the
# highest-numbered Pro Max.
runtimes_text, types_text = sys.stdin.read().split("<<SPLIT>>")
runtimes = [r for r in json.loads(runtimes_text)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
if not runtimes:
    print("ERROR\tNo iOS Simulator runtime is installed. Add one in Xcode > Settings > Components.")
    sys.exit()
runtimes.sort(key=lambda r: [int(p) for p in re.findall(r"\d+", r.get("version", "0"))], reverse=True)
listed = {t["identifier"]: t for t in json.loads(types_text)["devicetypes"]}


def models(runtime, kind="iPhone"):
    # kind="" matches every model (DEVICE_TYPE may name an iPad).
    supported = runtime.get("supportedDeviceTypes")
    if supported is None:
        return [t for t in listed.values() if kind in t.get("name", "")]
    return [listed.get(t["identifier"], t) for t in supported if kind in t.get("name", "")]


def screen(t):
    try:
        with open(os.path.join(t.get("bundlePath", ""), "Contents/Resources/profile.plist"), "rb") as f:
            profile = plistlib.load(f)
        w, h = int(profile["mainScreenWidth"]), int(profile["mainScreenHeight"])
        return (min(w, h), max(w, h))
    except Exception:
        return (0, 0)


def tall(t):
    w, h = screen(t)
    return w > 0 and h / w > 2.0


def number(t):
    return [int(n) for n in re.findall(r"\d+", t["name"])] or [0]


def choose():
    wanted = os.environ.get("DEVICE_TYPE")
    if wanted:
        for runtime in runtimes:
            for t in models(runtime, ""):
                if t["name"] == wanted:
                    return runtime, t
        return None
    # By screen size, where Xcode tells us: the 6.9-inch App Store size, else the biggest tall screen.
    for runtime in runtimes:
        exact = [t for t in models(runtime) if screen(t) == (1320, 2868)]
        if exact:
            return runtime, exact[-1]
    for runtime in runtimes:
        candidates = sorted([t for t in models(runtime) if tall(t)], key=lambda t: screen(t)[0] * screen(t)[1])
        if candidates:
            return runtime, candidates[-1]
    # Otherwise by name: the highest-numbered Pro Max (the largest regular iPhone each year).
    for runtime in runtimes:
        candidates = sorted([t for t in models(runtime) if t["name"].endswith("Pro Max")], key=number)
        if candidates:
            return runtime, candidates[-1]
    return None

picked = choose()
if picked:
    runtime, model = picked
    size = screen(model)
    print("OK\t" + runtime["identifier"] + "\t" + model["identifier"] + "\t" + model["name"] + "\t"
          + ("%d x %d" % size if size[0] else "size unknown"))
else:
    lines = []
    for runtime in runtimes:
        names = ", ".join(sorted({t["name"] for t in models(runtime, "" if os.environ.get("DEVICE_TYPE") else "iPhone")})) or "none"
        lines.append("  iOS " + runtime.get("version", "?") + ": " + names)
    wanted = os.environ.get("DEVICE_TYPE")
    print("ERROR\t" + ((wanted + " isn't available") if wanted else "No regular iPhone model found")
          + " in your installed Simulator runtimes:\n" + "\n".join(lines)
          + "\nAdd an iOS runtime in Xcode > Settings > Components, or pass DEVICE_TYPE=\"<one of these>\".")
PY

cat > "$HELPERS/udid.py" <<'PY'
import json, os, sys
devices = json.load(sys.stdin)["devices"].get(os.environ["RUNTIME"], [])
print(next((d["udid"] for d in devices if d["name"] == os.environ["SIM"] and d.get("isAvailable")), ""))
PY

# The runtime and model to run on (see pick.py above).
PICK="$( (json runtimes; echo; echo '<<SPLIT>>'; json devicetypes) | DEVICE_TYPE="${DEVICE_TYPE:-}" /usr/bin/python3 "$HELPERS/pick.py")"
if [[ "$PICK" != OK$'\t'* ]]; then echo "${PICK#*$'\t'}" >&2; exit 1; fi
PICK="${PICK#OK$'\t'}"
RUNTIME="${PICK%%$'\t'*}"
DEVICE_TYPE_ID="${PICK#*$'\t'}"
DEVICE_NAME="${DEVICE_TYPE_ID#*$'\t'}"
DEVICE_TYPE_ID="${DEVICE_TYPE_ID%%$'\t'*}"
DEVICE_SIZE="${DEVICE_NAME#*$'\t'}"
DEVICE_NAME="${DEVICE_NAME%%$'\t'*}"
echo "Using $DEVICE_NAME ($DEVICE_SIZE) on ${RUNTIME##*.}"
event device "$DEVICE_NAME" "$DEVICE_SIZE"
SIM="$SIM_NAME ($DEVICE_NAME)"

UDID="$(json devices | SIM="$SIM" RUNTIME="$RUNTIME" /usr/bin/python3 "$HELPERS/udid.py")"
if [[ -z "$UDID" ]]; then
  log "Creating the \"$SIM\" Simulator"
  UDID="$(xcrun simctl create "$SIM" "$DEVICE_TYPE_ID" "$RUNTIME")"
fi

log "Booting $SIM"
event phase booting
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
open -a Simulator --args -CurrentDeviceUDID "$UDID" || true

# MARK: Build and install

if [[ -z "${SKIP_BUILD:-}" || ! -d "$APP" ]]; then
  schemes="$(xcodebuild -list -project "$PROJECT" 2>/dev/null | sed -n '/Schemes:/,$p' || true)"
  if ! grep -qx "[[:space:]]*$SCHEME" <<< "$schemes"; then
    echo "The \"$SCHEME\" scheme wasn't found. Open $(basename "$PROJECT") in Xcode once (it creates the scheme)," >&2
    echo "or share it: Product › Scheme › Manage Schemes…, then tick Shared for $SCHEME." >&2
    exit 1
  fi
  log "Building $APP_NAME (Debug, Simulator)"
  event phase building
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -quiet \
    build
fi

log "Installing"
event phase installing
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

# The status bar Apple uses in its own screenshots.
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --operatorName "" \
  --batteryState charged --batteryLevel 100

# The text size: the one asked for, or the standard one (in case an earlier run changed it).
xcrun simctl ui "$UDID" content_size "${TEXT_SIZE:-large}"

# MARK: Capture

device_dir="$(echo "$DEVICE_NAME" | tr ' ' '-')"
if [[ -n "$WEB" ]]; then WEB="$(mkdir -p "$WEB" && cd "$WEB" && pwd)"; fi

for orientation in $ORIENTATIONS; do
  if [[ "$orientation" == landscape && "$DEVICE_NAME" == iPhone* ]]; then
    echo "Skipping landscape on $DEVICE_NAME: $APP_NAME runs in portrait on iPhone."
    event skipped landscape "$DEVICE_NAME"
    continue
  fi
  rotate "$orientation"
  suffix=""
  [[ "$orientation" == landscape ]] && suffix="-landscape"

  for appearance in $APPEARANCES; do
    log "Capturing ($appearance, $orientation)"
    event phase capturing "$appearance" "$orientation"
    xcrun simctl ui "$UDID" appearance "$appearance"
    dir="$OUT/$device_dir/$appearance$suffix${TEXT_SIZE:+-$TEXT_SIZE}"
    mkdir -p "$dir"

    for screen in "${SCREENS[@]}"; do
      number=0
      for i in "${!ALL_SCREENS[@]}"; do [[ "${ALL_SCREENS[$i]}" == "$screen" ]] && number=$((i + 1)); done
      file="$dir/$(printf '%02d' "$number")-$screen.png"

      xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
      xcrun simctl launch "$UDID" "$BUNDLE_ID" "$MODE_ARGUMENT" "$SCREEN_ARGUMENT" "$screen" >/dev/null
      sleep "$(settle_time "$screen")"
      xcrun simctl io "$UDID" screenshot --type=png "$file" >/dev/null 2>&1

      if [[ "$orientation" == landscape ]]; then
        width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')"
        height="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ { print $2 }')"
        if [[ -n "$width" && -n "$height" && "$height" -gt "$width" ]]; then
          sips --rotate "$LANDSCAPE_ROTATION" "$file" >/dev/null
        fi
      fi
      echo "  $screen  →  ${file#$ROOT/}"
      event saved "$screen" "$appearance" "$orientation" "$file"

      # Website copies come from the iPhone in portrait, at the standard text size.
      if [[ -n "$TEXT_SIZE" || "$orientation" != portrait || "$DEVICE_NAME" != iPhone* ]]; then
        :
      elif [[ -n "$WEB" && "$appearance" == "light" ]]; then
        sips --resampleWidth "$WEB_WIDTH" "$file" --out "$WEB/$screen.png" >/dev/null
      elif [[ -n "$WEB" && -n "$WEB_DARK" && "$appearance" == "dark" ]]; then
        sips --resampleWidth "$WEB_WIDTH" "$file" --out "$WEB/$screen-dark.png" >/dev/null
      fi
    done
  done
done
rotate portrait || true

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl status_bar "$UDID" clear || true
xcrun simctl ui "$UDID" content_size large || true

event done "$OUT/$device_dir"
log "Done"
echo "Full size:  ${OUT#$ROOT/}/$device_dir/"
[[ -n "$WEB" ]] && echo "Website:    $WEB/"
exit 0
