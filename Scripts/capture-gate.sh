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
# The phone must be **unlocked and awake**. A test host is a normal app and locks
# on the normal schedule; iOS tears the capture session down when the device locks,
# and there is no error to report afterwards.

set -o pipefail

DEVICE="${1:-00008150-00192CE23A7A401C}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$(mktemp -t capture-gate)"
GATE_NAME="Twenty moments, taken at a human pace, all succeed"

cd "$PROJECT_DIR" || exit 1

echo "Phase 4 capture gate — $DEVICE"
echo "Log: $LOG"
echo

# `-collect-test-diagnostics never` is mandatory, not a preference. Without it a
# failure tries to collect diagnostics, which hangs against a wedged capture
# daemon and reports `BUILD INTERRUPTED` — destroying the failure reason and
# costing a second twenty-minute run to find out what went wrong.
xcodebuild test \
    -project Memoree.xcodeproj \
    -scheme Memoree \
    -destination "platform=iOS,id=${DEVICE}" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=MBBD9BRZ67 \
    -collect-test-diagnostics never \
    -only-testing:MemoreeTests/LiveCaptureTests/twentyPacedMoments \
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
    echo "is indistinguishable from a pass unless you check. Either the test was"
    echo "renamed, or the identifier is wrong."
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