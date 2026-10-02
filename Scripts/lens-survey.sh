#!/bin/bash
#
# Stage 0 — survey what the camera hardware actually offers.
#
# ## Why this is a script and not just a test
#
# **Because the output is a print, not an assertion.** `surveyEveryLens` reports
# every built-in lens and whether a 3:4 format exists for it. Most of it
# deliberately does not assert — a measurement that can fail is not a measurement,
# and asserting on the ultra-wide row would fail the run while telling us nothing
# the table does not already say. So the result of interest is in the log, and a
# script has to be able to find it.
#
# It runs alone, for the same reason `capture-gate.sh` does and for a slightly
# different reason: this survey allocates **no** capture session, so it is safe to
# share a process — but it runs first in its own so that its output is not buried
# under twenty minutes of Phase 4 gate, and so a wedged capture daemon from an
# earlier run cannot stop us getting the numbers.
#
# ## The three checks at the end are the same ones the gate script learned
#
# 1. `-collect-test-diagnostics never`, mandatory. Without it a failure tries to
#    collect diagnostics against a possibly-wedged capture daemon, hangs, and
#    reports `BUILD INTERRUPTED` — destroying the reason.
# 2. The empty parentheses in the identifier are **load-bearing**: a Swift Testing
#    identifier is `functionName(displayName)`, and with a custom display name the
#    argument list is empty.
# 3. Grep for the test's own name and fail if absent. `-only-testing:` with a
#    misspelled identifier matches nothing and xcodebuild reports
#    `** TEST SUCCEEDED **` with exit 0. This project has been bitten three times
#    by something that looked like a pass and asserted nothing, so the check is
#    not decoration.
#
# ## Usage
#
#     Scripts/lens-survey.sh                 # the connected device
#     Scripts/lens-survey.sh <udid>          # a named device
#
# The phone must be **unlocked and awake** for the same reason the gate requires
# it: iOS tears the capture session down when the device locks.

set -o pipefail

DEVICE="${1:-00008150-00192CE23A7A401C}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$(mktemp -t lens-survey)"
SURVEY_NAME="DEVICE ONLY — survey every built-in lens"
SURVEY_TABLE="LENS SURVEY"

cd "$PROJECT_DIR" || exit 1

echo "Stage 0 lens survey — $DEVICE"
echo "Log: $LOG"
echo

xcodebuild test \
    -project Memoree.xcodeproj \
    -scheme Memoree \
    -destination "platform=iOS,id=${DEVICE}" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=MBBD9BRZ67 \
    -collect-test-diagnostics never \
    "-only-testing:MemoreeTests/LiveCaptureTests/surveyEveryLens()" \
    >"$LOG" 2>&1
STATUS=$?

echo "--- survey result ---"

if ! grep -q "$SURVEY_NAME" "$LOG"; then
    echo "FAIL — the survey did not run."
    echo
    echo "xcodebuild exited $STATUS and never mentioned '$SURVEY_NAME'."
    echo "That is the silent-skip failure: -only-testing matched nothing, which is"
    echo "indistinguishable from a pass unless you check. See the note in"
    echo "Scripts/capture-gate.sh about the empty parentheses."
    echo
    echo "Tail of the log:"
    tail -40 "$LOG"
    exit 1
fi

if grep -qE "✘.*survey every built-in lens" "$LOG"; then
    echo "FAIL — the survey ran and the assertion failed."
    echo "The table still printed; read it, then read the failure below."
    echo
    sed -n '/LENS SURVEY/,/^└/p' "$LOG"
    echo
    tail -30 "$LOG"
    exit 1
fi

if [ $STATUS -ne 0 ]; then
    echo "INCONCLUSIVE — the survey ran but xcodebuild exited $STATUS."
    echo
    tail -40 "$LOG"
    exit 1
fi

# The table is the deliverable, so print it rather than making the reader open
# the log. It is written to stdout by the test, so grep it back out.
echo "PASS — the survey ran."
echo
sed -n '/LENS SURVEY/,/^└/p' "$LOG"
sed -n '/Device types not in this survey/,+1p' "$LOG"
echo
echo "Reading the table:"
echo "  3:4?       NO means the selector would throw noThreeByFourFormat on"
echo "             every press, so that lens cannot carry a control at all."
echo "  zoom       The ceiling is per-format and will read absurdly high — it is"
echo "             the point at which AVFoundation still accepts a number."
echo "  upscale>   Where real magnification stops and digital enlargement"
echo "             starts. This is the number to design a zoom control against."
echo "  switch-over  Only virtual devices have these. Non-empty means AVFoundation"
echo "             can hand off between lenses for us — seamless zoom with no"
echo "             session restart, which is what would make Stage 4 cheap."
echo
echo "Full log: $LOG"
exit 0