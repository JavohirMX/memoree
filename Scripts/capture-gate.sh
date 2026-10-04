#!/bin/bash
#
# The Phase 4 capture gates, each in its own process.
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
# (0.583s on a fresh service, 200.8s on a shared one). So each gate runs alone.
# One allocation, which is the shape that is known to work.
#
# ## Why there are two gates
#
# `twentyPacedMomentsWithBTS` is the same twenty moments **with an
# `AVCaptureMovieFileOutput` attached**, and it is a separate invocation rather than
# a flag on the first for one reason: the first gate's number is a baseline.
#
# **A baseline you replace is not a baseline.** Its whole value is being comparable
# to the 19/20 recorded on 2026-10-03, one capture-daemon death and one recovery.
# Running BTS inside it would answer "does the extra output hurt?" by replacing the
# thing being compared, and a regression in either direction would be invisible.
#
# **Both run, always, and both are reported.** Running only the second would say
# nothing about what changed; running only the first would not notice that Phase 10
# attached a third output to the session the gate stress-tests. Two device runs of
# four minutes each is the cost of a comparison that means something, and the
# alternative is a green tick that could have come from either change.
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
# greps the output for each gate's own name and fails if it is absent. A gate that
# did not run must never look like a gate that passed.
#
# ## Usage
#
#     Scripts/capture-gate.sh                 # the connected device
#     Scripts/capture-gate.sh <udid>          # a named device
#
# The phone must be **unlocked and awake** for *both* test runs. A test host is a
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
# the runs themselves**, which is the difference between a gate that measures
# something and one that mostly measures whether someone was holding the phone.
#
# `test-without-building` is also faster for the ordinary reason: no rebuild between
# the phases.

set -o pipefail

DEVICE="${1:-00008150-00192CE23A7A401C}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_LOG="$(mktemp -t capture-gate-build)"
GATE_LOG="$(mktemp -t capture-gate-run)"

# The gate's Swift Testing function name and its display name, kept together
# because the two must agree and a mismatch is the silent-skip failure.
GATE_A_ID="twentyPacedMoments()"
GATE_A_NAME="Twenty moments, taken at a human pace, all succeed"
GATE_B_ID="twentyPacedMomentsWithBTS()"
GATE_B_NAME="Twenty moments with Behind the Scenes recording, all succeed"

cd "$PROJECT_DIR" || exit 1

echo "Phase 4 capture gates — $DEVICE"
echo "Build log: $BUILD_LOG"
echo "Run log:   $GATE_LOG"
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
    >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?

if [ $BUILD_STATUS -ne 0 ]; then
    echo "FAIL — the build did not succeed, so there is nothing to run."
    echo
    tail -40 "$BUILD_LOG"
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
    echo "Both runs are about to start and take several minutes each. If the device"
    echo "locks, every moment fails instantly with 'hasFigCaptureSession' and the"
    echo "gate measures nothing — which is what happened before this script was split."
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

# Echoes its own name into the log and reports whether the gate passed.
#
# # The three verdicts are distinct and all three are needed
#
# "Did not run" and "ran and failed" look identical from outside — a green
# `xcodebuild` with no output is precisely what a misspelled identifier produces —
# and a third verdict exists for the case where the gate reported nothing wrong but
# the process did not finish, which is a wedged daemon rather than a result.
#
# # The "did it run" check needs *two* signals, and the second one is new
#
# Grepping for the display name is not enough, because **Swift Testing reports a
# skipped test by name.** A gate that hit `requireCamera()` and returned early
# appears in the log under its own name and would pass a name-only check — which is
# the precise failure this script exists to prevent, arriving through a different
# door. So each gate also has to print its own summary line, which only happens
# after the twenty-moment loop has actually run. A skip prints the banner and no
# summary, and a banner is not a measurement.
#
# Returns 0 for pass, 1 for anything else. The caller decides whether that ends
# the script; it does not, because the second gate is still worth running.
run_gate() {
    local identifier="$1"
    local display_name="$2"
    local summary_prefix="$3"

    xcodebuild test-without-building \
        -project Memoree.xcodeproj \
        -scheme Memoree \
        -destination "platform=iOS,id=${DEVICE}" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM=MBBD9BRZ67 \
        -collect-test-diagnostics never \
        "-only-testing:MemoreeTests/LiveCaptureTests/${identifier}" \
        >>"$GATE_LOG" 2>&1
    local status=$?

    echo "=== $display_name ==="
    echo "xcodebuild exited $status"

    # The gate must appear *and* not be reported as failed. Both checks, because a
    # name appearing in a failure banner proves nothing.
    if ! grep -q "$display_name" "$GATE_LOG"; then
        echo "DID NOT RUN — the log never mentioned the gate."
        echo "That is the silent-skip failure: -only-testing matched nothing, which"
        echo "is indistinguishable from a pass unless you check. The usual cause is"
        echo "a wrong identifier — see the note above about the empty parentheses."
        echo
        echo "Tail of the log:"
        tail -40 "$GATE_LOG"
        return 1
    fi

    # **The second signal.** See above: a skipped test is named in the log.
    if ! grep -q "$summary_prefix" "$GATE_LOG"; then
        echo "DID NOT RUN — the gate was named but printed no measurements."
        echo "That means it was skipped, not that it passed. On a device the usual"
        echo "cause is a camera that could not be opened; on this host, check the"
        echo "log for the SKIPPED banner the live suite prints when it bails."
        echo
        echo "Tail of the log:"
        tail -40 "$GATE_LOG"
        return 1
    fi

    if grep -qE "✘.*${display_name}" "$GATE_LOG"; then
        echo "FAILED — the gate ran and did not pass."
        echo
        grep -E "live (capture|BTS)|SESSION-REBUILDS|FRAME-WAITS summary|needed the retry|✘" "$GATE_LOG" \
            | tail -40
        return 1
    fi

    if [ $status -ne 0 ]; then
        # The gate's name is in the log and it is not marked failed, so something
        # else went wrong — most likely the run being interrupted. Worth saying
        # plainly rather than reporting a pass.
        echo "INCONCLUSIVE — the gate's name is in the log but xcodebuild exited $status."
        echo "The gate did not report a failure, but the run did not finish cleanly."
        return 1
    fi

    echo "PASSED"
    grep -E "live (capture|BTS)|SESSION-REBUILDS|FRAME-WAITS summary|needed the retry" "$GATE_LOG" \
        | tail -20
    return 0
}

# **The run log is appended to, not truncated, so the diagnostic lines from the
# first gate are still there when the second one runs.** `run_gate` greps the whole
# file for its display name, and two names in one file is fine — they are distinct
# strings — while two logs would mean a reader comparing two `SESSION-REBUILDS`
# numbers has to know which file is which.
: >"$GATE_LOG"

run_gate "$GATE_A_ID" "$GATE_A_NAME" "live capture: 20 paced moments"
A=$?

echo
run_gate "$GATE_B_ID" "$GATE_B_NAME" "live BTS: 20 paced moments"
B=$?

echo
echo "--- both gates ---"
echo "photographs only : $([ $A -eq 0 ] && echo PASS || echo "NOT PASSING (exit $A)")"
echo "with BTS recording: $([ $B -eq 0 ] && echo PASS || echo "NOT PASSING (exit $B)")"
echo
echo "Full output: $GATE_LOG"
echo

if [ $A -ne 0 ] || [ $B -ne 0 ]; then
    echo "FAIL — see above. Record the numbers in docs/IMPLEMENTATION_PLAN.md"
    echo "whatever they are; a regression is only visible against the previous run."
    exit 1
fi

echo "PASS — both gates"
echo
echo "Phase 4's exit criterion is met, and a third output on the session did not"
echo "change it. Remember to record the numbers in docs/IMPLEMENTATION_PLAN.md."
exit 0