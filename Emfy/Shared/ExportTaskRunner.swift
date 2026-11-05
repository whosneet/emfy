import Foundation

/// Runs one off-main, cancellable export render and shows a spinner only if it
/// takes longer than ~0.3 s. Cross-platform (C2): Foundation and Swift
/// concurrency only, so it's shared and unit-testable on both platforms.
///
/// Resilience (§k):
/// - It actually cancels the detached render. A detached task does not inherit
///   cancellation, so without `withTaskCancellationHandler` cancelling the runner
///   would leave the render burning CPU to completion; here cancelling propagates
///   to the detached task, which observes `Task.isCancelled` cooperatively.
/// - At most one render is in flight. Starting a new render cancels the previous
///   and **awaits it** before launching the next detached render, so two renders
///   never run at once (which matters with the kept 2× / 32 MP export parity).
///
/// A generation token keeps a stale render from touching the busy flag or
/// delivering a late result.
@MainActor
final class ExportTaskRunner {
    private var task: Task<Void, Never>?
    private var generation = 0

    /// - Parameters:
    ///   - setBusy: toggles the surface's "rendering" flag (drives the spinner).
    ///   - render: the pure, `Sendable` render, run on a detached task. It should
    ///     check `Task.isCancelled` at coarse points so cancellation takes effect.
    ///   - done: receives the render result on the main actor; skipped if a newer
    ///     render has started or this one was cancelled.
    func run<T: Sendable>(
        setBusy: @escaping @MainActor (Bool) -> Void,
        render: @escaping @Sendable () -> T,
        done: @escaping @MainActor (T) -> Void
    ) {
        let previous = task
        previous?.cancel()
        generation &+= 1
        let generationAtStart = generation
        task = Task { @MainActor in
            // At most one render in flight: let the previous one finish unwinding
            // (it was just cancelled) before starting a new detached render.
            await previous?.value
            guard generationAtStart == self.generation, !Task.isCancelled else { return }

            let spinner = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled, generationAtStart == self.generation else { return }
                setBusy(true)
            }

            let renderTask = Task.detached(priority: .userInitiated, operation: render)
            let value = await withTaskCancellationHandler {
                await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }

            spinner.cancel()
            guard generationAtStart == self.generation else { return }
            setBusy(false)
            if Task.isCancelled { return }
            done(value)
        }
    }

    /// Cancels any in-flight render (e.g. the view disappeared). The caller resets
    /// its own busy flag.
    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }
}
