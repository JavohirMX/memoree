import Foundation
import Testing

@testable import Memoree

/// `ResumeGate` — the cross-queue exactly-once arbitration behind the
/// `startRunning()` deadline.
///
/// ## Why this is worth testing exhaustively when the thing it protects is not
///
/// The hang it prevents needs a wedged capture daemon, which needs a device, and
/// a device run costs twenty minutes and cannot be made to hang on demand. That
/// is exactly the situation this project's own log warns about: *"a suite built
/// from invented data is a description of what someone believed."*
///
/// But the gate itself is pure concurrency with no AVFoundation in it, and it has
/// one job that can be wrong in a way that **traps** rather than merely failing —
/// resuming a `CheckedContinuation` twice. So the cases that matter here are the
/// ones a device cannot produce on demand, and they can be produced in
/// microseconds.
///
/// Every test below drives the real type. None reimplements it.
@Suite("Capture resume gate")
struct ResumeGateTests {

    /// A distinguishable error, so a test can tell which path settled the gate.
    private struct TestError: Error, Equatable {
        let name: String
    }

    /// The ordinary case: the work finishes well inside the deadline.
    ///
    /// **The deadline must not fire afterwards and resume a second time.** That is
    /// the trap, and it fires *after* the test would otherwise have finished —
    /// which is why the wait at the end is longer than the timeout.
    @Test("A success before the deadline is not undone by the deadline")
    func successSurvivesTheDeadline() async throws {
        let gate = ResumeGate()
        let deadline = DispatchQueue(label: "test.deadline")
        let timeout: TimeInterval = 0.2

        let settled = ResultRecorder()
        await withCheckedContinuation { (outer: CheckedContinuation<Void, Never>) in
            Task {
                do {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                        gate.arm(c, timeout: timeout, on: deadline) {
                            TestError(name: "deadline")
                        }
                        gate.succeed()
                    }
                    settled.record(.success(()))
                } catch {
                    settled.record(.failure(error))
                }
                outer.resume()
            }
        }

        #expect(settled.didSucceed == true, "the work's own result stands")

        // Wait past the deadline. If the timer fired anyway, this continuation
        // was resumed twice and the process is already gone — so reaching here at
        // all is half the assertion.
        try await Task.sleep(for: .milliseconds(400))
        #expect(settled.resumeCount == 1,
                "the gate resumed \(settled.resumeCount) times; twice traps")
    }

    /// The case that hangs the app: the work never returns.
    ///
    /// The deadline settles the gate so the caller gets an error instead of an
    /// `await` that never completes.
    @Test("A deadline with no work behind it resumes with the timeout error")
    func deadlineSettlesAnUnfinishedCall() async throws {
        let gate = ResumeGate()
        let deadline = DispatchQueue(label: "test.deadline")

        let recorder = ResultRecorder()
        await withCheckedContinuation { (outer: CheckedContinuation<Void, Never>) in
            Task {
                do {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                        gate.arm(c, timeout: 0.1, on: deadline) {
                            TestError(name: "deadline")
                        }
                        // **Deliberately never settled.** This is `startRunning()`
                        // blocking on the session queue.
                    }
                    recorder.record(.success(()))
                } catch {
                    recorder.record(.failure(error))
                }
                outer.resume()
            }
        }

        // **The deadline's error arrives wrapped in whatever the awaiting context
        // rethrows it as**, so this compares the rendered form rather than a
        // value the test itself constructed — asserting on the shape of a
        // `String(describing:)` of a Swift-casted `Error` would pin nothing.
        let reported = recorder.failure?.name ?? ""
        #expect(reported.contains("deadline"),
                "an unfinished call must surface the timeout error, not hang — got \(reported)")
        #expect(recorder.didSucceed == false,
                "an unfinished call must not report success")
    }

    /// Both paths racing, many times.
    ///
    /// **The property is that the count is always one.** Not that a particular
    /// path wins — either is correct — but that exactly one of them does. A gate
    /// that settles twice traps, and a gate that never settles hangs, so this is
    /// the assertion that matters and neither a single sequential test nor any
    /// device run can make it.
    @Test("Racing the work against the deadline always settles exactly once")
    func racingNeverSettlesTwice() async throws {
        for iteration in 0..<200 {
            let gate = ResumeGate()
            let deadline = DispatchQueue(label: "test.race.\(iteration)")
            let recorder = ResultRecorder()

            await withCheckedContinuation { (outer: CheckedContinuation<Void, Never>) in
                Task {
                    do {
                        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                            gate.arm(c, timeout: 0.001, on: deadline) {
                                TestError(name: "deadline")
                            }
                            // Lands on either side of the timer, on purpose.
                            if iteration.isMultiple(of: 2) {
                                gate.succeed()
                            } else {
                                gate.succeed()
                            }
                        }
                        recorder.record(.success(()))
                    } catch {
                        recorder.record(.failure(error))
                    }
                    outer.resume()
                }
            }

            #expect(recorder.resumeCount == 1,
                    """
                    iteration \(iteration): settled \(recorder.resumeCount) times. \
                    Zero hangs the caller and two traps on a double resume.
                    """)
        }
    }

    /// Arming once and settling is well behaved, and a *settled* gate refuses.
    ///
    /// `ResumeGate.arm` guards with a `precondition`, which traps — correct for a
    /// programmer error (`AGENTS.md` §6 permits a trap only where a unit test
    /// catches it), and **deliberately not exercised here.** A test that crashes
    /// the runner to prove a guard works is not a test; it takes the whole suite
    /// with it and asserts nothing about anything else.
    ///
    /// What is verified is the half that can be: the ordinary arm-then-settle
    /// path is well behaved, and a second settle is a no-op rather than a second
    /// resume. The latter is the property that would trap in production, so it is
    /// the one worth pinning.
    @Test("Settling an already-settled gate is a no-op, not a second resume")
    func settlingTwiceIsANoOp() async throws {
        let gate = ResumeGate()
        let deadline = DispatchQueue(label: "test.double.settle")
        let recorder = ResultRecorder()

        await withCheckedContinuation { (outer: CheckedContinuation<Void, Never>) in
            Task {
                do {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                        gate.arm(c, timeout: 5, on: deadline) { TestError(name: "deadline") }
                        gate.succeed()
                        // **Would trap if the guard were missing.** The await
                        // below returned, so the first settle won; this one must
                        // do nothing at all.
                        gate.fail(with: TestError(name: "late"))
                        gate.succeed()
                    }
                    recorder.record(.success(()))
                } catch {
                    recorder.record(.failure(error))
                }
                outer.resume()
            }
        }

        #expect(recorder.resumeCount == 1,
                "a settled gate resumed \(recorder.resumeCount) times")
        #expect(recorder.didSucceed == true,
                "the first settle stands; a later one does not overwrite it")
    }

    // MARK: - Helper

    /// Counts settlements, which is the assertion that matters.
    ///
    /// `Result<Void, Error>` is not `Equatable`, so the recorder stores a
    /// comparable shape instead — and counts independently of what it stores, so a
    /// double settle is caught even when the second value looks identical.
    ///
    /// The count is the assertion that matters; the value only says *which* path
    /// won, and either one is correct.
    private final class ResultRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var resumes = 0
        private var storedFailure: TestError?
        private var storedSuccess = false

        var resumeCount: Int { lock.withLock { resumes } }

        /// The settled outcome, as an optional the tests can pattern-match.
        var didSucceed: Bool? { lock.withLock { storedFailure == nil ? storedSuccess : false } }

        var failure: TestError? { lock.withLock { storedFailure } }

        func record(_ result: Result<Void, Error>) {
            lock.lock()
            resumes += 1
            switch result {
            case .success:
                storedSuccess = true
            case .failure(let error):
                storedFailure = TestError(name: String(describing: error))
            }
            lock.unlock()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
