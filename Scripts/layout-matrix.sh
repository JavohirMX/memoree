#!/bin/bash
#
# The layout matrix: every screen, both orientations, with real photographs.
#
# ## Why this exists
#
# **Landscape had never been seen.** Phase 4 enabled landscape left and right
# because a landscape photograph could not otherwise be taken, and four latent
# layout bugs were found by *reasoning* about it. The plan then recorded, as an
# open item, that the layouts "have not been looked at sideways" — and could not
# be, because rotating a simulator needs the Simulator GUI, which is not
# installed on this machine.
#
# There is no `simctl` subcommand for orientation. `simctl io … screenshot`
# captures whatever the device is showing and nothing available can change what
# that is.
#
# So the app asks the window to rotate itself: `-MemoreeForceLandscape` calls
# `requestGeometryUpdate`, which is the supported way, and is a DEBUG launch
# argument alongside `-MemoreeOpen`, `-MemoreeSkipOnboarding` and
# `-MemoreeSeedMoments`. **A layout that has never been rendered is a layout
# nobody has checked**, and this project's own record is that looking finds
# strictly more than reasoning: all four of the orientation-phase defects were
# found by holding the phone, and none by reading the code.
#
# ## Photographs, not grey rectangles
#
# `-MemoreeSeedMoments` deliberately writes no asset identifiers, so a debug
# launch cannot put photographs into a *user's* camera roll (ADR-008). The
# consequence is that every cell renders as an empty rectangle — which exercises
# none of the geometry that matters: the `scaledToFit` mat, the front inset sized
# from the short side, the composite renderer.
#
# `-MemoreeSeedWithPhotos` attaches real identifiers **already in the
# simulator's library**, and is gated at runtime on `SIMULATOR_DEVICE_NAME`
# rather than on `#if targetEnvironment(simulator)` — a compile-time check cannot
# guard a runtime flag, because the same Debug build is what a device run
# installs.
#
# ## Usage
#
#     Scripts/layout-matrix.sh [udid] [output-directory]
#
# Put photographs in the simulator's library first:
#
#     xcrun simctl addmedia <udid> portrait.png landscape.png
#
# Grant permissions, or the alert will sit on top of every screenshot — and
# `simctl` cannot tap it, so there is no way past it but a fresh grant:
#
#     xcrun simctl privacy <udid> grant camera <bundle>
#     xcrun simctl privacy <udid> grant photos-add <bundle>
#
# **Grant before the first launch, not after.** Granting `photos` (read-write)
# alongside `photos-add` makes Photos escalate to a "full access" prompt, which
# then covers the app for the rest of the session.

set -o pipefail

DEVICE="${1:-186ACC05-AC93-4A05-BB8D-23DE67C5766A}"
BUNDLE="com.javohirmx.memoree"
OUT="${2:-/tmp/memoree-matrix}"
SEED=60

mkdir -p "$OUT"
rm -f "$OUT"/*.png

echo "Memoree layout matrix — $DEVICE"
echo "Output: $OUT"
echo

# `cap name extra-flags…`
cap() {
    local name="$1"; shift
    xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE" "$@" >/dev/null 2>&1
    sleep 9
    xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png" >/dev/null 2>&1
    echo "  $name"
}

BASE=(-MemoreeSkipOnboarding "-MemoreeSeedMoments=$SEED")
LAND=(-MemoreeForceLandscape)

echo "=== ARCHIVE, WITH PHOTOGRAPHS ==="
cap 01-archive-portrait   "${BASE[@]}" -MemoreeSeedWithPhotos -MemoreeOpen archive
cap 02-archive-landscape  "${BASE[@]}" -MemoreeSeedWithPhotos "${LAND[@]}" -MemoreeOpen archive

echo "=== TODAY ==="
cap 03-today-portrait     "${BASE[@]}" -MemoreeSeedWithPhotos
cap 04-today-landscape    "${BASE[@]}" -MemoreeSeedWithPhotos "${LAND[@]}"

echo "=== STATS ==="
cap 05-stats-portrait     "${BASE[@]}" -MemoreeOpen stats
cap 06-stats-landscape    "${BASE[@]}" "${LAND[@]}" -MemoreeOpen stats

echo "=== SETTINGS ==="
cap 07-settings-portrait  "${BASE[@]}" -MemoreeOpen settings
cap 08-settings-landscape "${BASE[@]}" "${LAND[@]}" -MemoreeOpen settings

echo "=== CAMERA ==="
cap 09-camera-portrait    "${BASE[@]}" -MemoreeOpen camera
cap 10-camera-landscape   "${BASE[@]}" "${LAND[@]}" -MemoreeOpen camera

echo
echo "=== EMPTY STATES AND FIRST RUN ==="
echo "(wipes the store, so onboarding is genuinely first-run)"

DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
rm -f "$DATA/Library/Application Support/default.store"*

cap 11-archive-empty-portrait  -MemoreeSkipOnboarding -MemoreeOpen archive
cap 12-archive-empty-landscape -MemoreeSkipOnboarding "${LAND[@]}" -MemoreeOpen archive
cap 13-onboarding-portrait
cap 14-onboarding-landscape   "${LAND[@]}"

echo
# **Both configurations, and this is not optional housekeeping.**
#
# The flags this script passes are DEBUG-only, so a Release build does not
# compile the code that reads them. That happened while this script was being
# written: Debug built clean, Release failed, and **every gate the project has
# ever run was a Debug gate** — the suite, the device runs, the lint. A
# configuration nobody builds is a configuration nobody checks, and
# `AGENTS.md` §12 asks for zero warnings without qualifying which build produced
# them.
#
# Release is not installed or launched. It is only compiled, because compiling it
# is the check that catches a DEBUG-only symbol leaking into production code.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1
for config in Debug Release; do
    if xcodebuild build \
        -project Memoree.xcodeproj \
        -scheme Memoree \
        -configuration "$config" \
        -destination 'platform=iOS Simulator,name=iPhone 17' \
        -collect-test-diagnostics never \
        >/tmp/memoree-layout-$config.log 2>&1; then
        echo "  $config build ok"
    else
        echo "  $config BUILD FAILED — see /tmp/memoree-layout-$config.log"
        grep -E "error:" /tmp/memoree-layout-$config.log | head -5
        exit 1
    fi
done

echo
echo "Done. $(ls -1 "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') screenshots in $OUT"