#!/bin/bash
#
# The Phase 4 capture gate, in its own process.
#
# ## Why this exists
#
# `twentyPacedMoments` is Phase 4's exit criterion: twenty real captures, twenty
# real camera swaps, all succeeding. It cannot be measured in a process that also
# runs the rest of `LiveCaptureTests`.
#
# **One device run of that suite allocates eight `AVCaptureSession`s back to
# back.** `AVCaptureSession.init()` is a *synchronous* XPC round-trip to the
# capture daemon (`FigCaptureSessionRemoteCreate`), and eight of them in one
# background test process is enough to wedge it. Three device runs failed this way,
# each differently, which is the signature of an unreliable harness rather than a
# regression. The findings are recorded in `LiveCaptureTests`' own documentation.
#
# The two alternative fixes both break something — one shared service means the
# destructive `rebuildSession` test wrecks the instance for everything after it
# (0.583s on a fresh service, 200.8s on a shared one). So the gate runs alone.
# One allocation, which is the shape that is known to work.
#
# ## Why this script and not a scheme
#
# A scheme cannot select a single *test method* — only a target or a suite — so
# expressing "the gate, and nothing else" needs either a suite of its own or a
# command line. A script is the command line, and it also gets to check the one
# thing a scheme cannot.
#
# ## The check at the end is not decoration
#
# **`-only-testing:` with a misspelled or renamed identifier matches nothing, and
# xcodebuild reports success.** That is this project's recurring failure mode: four
# Phase 3 tests "passed" in a millisecond while asserting nothing, and a
# twenty-moment run once reported zero iterations as if it had finished. So this
# greps the output for the gate's own name and fails if it is absent. A gate that
# did not run must never look like a gate that passed.
#
# ## Usage
#
#     Scripts/capture-gate.sh                 # the connected device
#     Scripts/capture-gate.sh <udid>          # a named device
#
# The phone must be **unlocked and awake** for the *test run*. A test host is a
# normal app and locks on the normal schedule; iOS tears the capture session down
# when the device locks, and there is no error to report afterwards.
#
# ## Why this builds first, separately — and why that is not an optimisation
#
# The first run of this script, on a device that had been idle, reported **0/20**
# in **0.12 seconds**. Every moment failed instantly with
# `AVCapturePhotoOutput` bailing on `"hasFigCaptureSession"` — the output had no
# session behind it at all. Not the daemon death this gate exists to investigate,
# and not a slow camera: nothing had started.
#
# The cause is the harness. `xcodebuild test` builds, installs and *then* runs, and
# on this machine the build and install take **four and a half minutes**. The plan
# has already recorded that a locked test host is the likely reason the earlier runs
# reported a dead capture daemon — *"a test host is a normal app and locks on the
# normal schedule, and a twenty-moment run is longer than that schedule."* That is
# the same fact, and it was costing the gate its meaning in a way that looked
# exactly like a capture defect.
#
# So the build happens first, while the phone may be locked and does not matter,
# and only then does the script stop and wait for a human. **The window in which
# the device has to be awake shrinks from four and a half minutes to the length of
# the run itself**, which is the difference between a gate that measures something
# and one that mostly measures whether someone was holding the phone.
#
# `test-without-building` is also faster for the ordinary reason: no rebuild between
# the two phases.

set -o pipefail

DEVICE="${1:-00008150-00192CE23A7A401C}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$(mktemp -t capture-gate)"
GATE_NAME="Twenty moments, taken at a human pace, all succeed"

cd "$PROJECT_DIR" || exit 1

echo "Phase 4 capture gate — $DEVICE"
echo "Log: $LOG"
echo

# Phase 1 — build. The phone does not need to be awake, unlocked, or even present.
echo "--- building (the phone may be locked) ---"
xcodebuild build-for-testing \
    -project Memoree.xcodeproj \
    -scheme Memoree \
    -destination "platform=iOS,id=${DEVICE}" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=MBBD9BRZ67 \
    -collect-test-diagnostics never \
    >"$LOG" 2>&1
BUILD_STATUS=$?

if [ $BUILD_STATUS -ne 0 ]; then
    echo "FAIL — the build did not succeed, so there is nothing to run."
    echo
    tail -40 "$LOG"
    exit 1
fi

echo "build ok"
echo

# Phase 2 — stop and wait. Four and a half minutes of build used to happen here,
# silently, with the phone going to sleep in the middle of it.
#
# `MEMOREE_GATE_ASSUME_AWAKE=1` skips the prompt for a run that is already
# orchestrated — the caller has just checked, and cannot usefully ask a human
# through a pipe. It is opt-in precisely because assuming wrongly is the failure
# this split exists to catch.
if [ -n "${MEMOREE_GATE_ASSUME_AWAKE:-}" ]; then
    echo "MEMOREE_GATE_ASSUME_AWAKE is set — not waiting for confirmation."
    echo "If every moment fails instantly with 'hasFigCaptureSession', the"
    echo "device was asleep. That is this, and it is not a capture defect."
else
    echo "=== UNLOCK THE PHONE AND LEAVE IT AWAKE ==="
    echo "The run is about to start and takes several minutes. If the device locks,"
    echo "every moment fails instantly with 'hasFigCaptureSession' and the gate"
    echo "measures nothing — which is what happened before this script was split."
    echo
    printf "Press return once the screen is on and the phone is in your hand: "
    read -r _
fi
echo

# `-collect-test-diagnostics never` is mandatory, not a preference. Without it a
# failure tries to collect diagnostics, which hangs against a wedged capture
# daemon and reports `BUILD INTERRUPTED` — destroying the failure reason and
# costing a second twenty-minute run to find out what went wrong.
# The empty parentheses are load-bearing: a Swift Testing test's identifier is
# `functionName(displayName)`, and with a custom display name the argument list
# is *empty* — `twentyPacedMoments()`, not `twentyPacedMoments` and not
# `twentyPacedMoments(Twenty moments, taken at a human pace, all succeed)`.
#
# **Verified, at a cost of one real device run.** The first version of this
# script omitted them, matched nothing, and reported success. The grep check
# below caught it — which is the check earning its keep — but the run still cost
# four minutes. `xcodebuild -enumerate-tests` is the fast way to confirm an
# identifier, and this comment exists so the next person does not re-derive it.
#
#   xcodebuild test -project Memoree.xcodeproj -scheme Memoree \
#     -destination 'platform=iOS Simulator,name=iPhone 17' \
#     -enumerate-tests -test-enumeration-format json \
#     -test-enumeration-output-path /tmp/tests.json
#
# Note also that xcodebuild's *XCTest* counter reads "Executed 0 tests" for every
# Swift Testing run, on every platform. That is not a skip — read the Swift
# Testing line, "Test run with N tests in M suites", or you will misdiagnose a
# perfectly good run as an empty one. It was misread here.
xcodebuild test-without-building \
    -project Memoree.xcodeproj \
    -scheme Memoree \
    -destination "platform=iOS,id=${DEVICE}" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=MBBD9BRZ67 \
    -collect-test-diagnostics never \
    "-only-testing:MemoreeTests/LiveCaptureTests/twentyPacedMoments()" \
    >"$LOG" 2>&1
STATUS=$?

echo
echo "--- gate result ---"

# The gate must appear *and* not be reported as failed. Both checks, because a
# name appearing in a failure banner proves nothing.
if ! grep -q "$GATE_NAME" "$LOG"; then
    echo "FAIL — the gate did not run."
    echo
    echo "xcodebuild exited $STATUS and never mentioned '$GATE_NAME'."
    echo "That is the silent-skip failure: -only-testing matched nothing, which"
    echo "is indistinguishable from a pass unless you check. The usual cause is"
    echo "a wrong identifier — see the note above about the empty parentheses."
    echo
    echo "Tail of the log:"
    tail -40 "$LOG"
    exit 1
fi

if grep -qE "✘.*Twenty moments" "$LOG"; then
    echo "FAIL — the gate ran and did not pass."
    echo
    tail -60 "$LOG"
    exit 1
fi

if [ $STATUS -ne 0 ]; then
    # The gate's name is in the log and it is not marked failed, so something
    # else went wrong — most likely the run being interrupted. Worth saying
    # plainly rather than reporting a pass.
    echo "INCONCLUSIVE — the gate's name is in the log but xcodebuild exited $STATUS."
    echo "The gate did not report a failure, but the run did not finish cleanly."
    echo
    tail -60 "$LOG"
    exit 1
fi

echo "PASS — $GATE_NAME"
echo
echo "Phase 4's exit criterion is met: twenty paced captures, all succeeding."
echo "Remember to record it in docs/IMPLEMENTATION_PLAN.md."
exit 0