import Foundation
import ScreenCaptureKit
import CoreMedia

/// Lowers delivery at the capture source too. All methods run on the recording's
/// serial media queue; updates are coalesced while ScreenCaptureKit applies one.
final class RecordingAdaptiveCapture: @unchecked Sendable {
    private let stream: SCStream
    private let configuration: SCStreamConfiguration
    private let policy: RecordingFramePolicy
    private let queue: DispatchQueue
    private let reportError: (Error) -> Void
    private var timer: DispatchSourceTimer?
    private var appliedFPS: Double
    private var requestedFPS: Double
    private var updating = false
    private var active = true

    init(stream: SCStream, configuration: SCStreamConfiguration, options: RecordingOptions,
         policy: RecordingFramePolicy, queue: DispatchQueue, reportError: @escaping (Error) -> Void) {
        self.stream = stream
        self.configuration = configuration
        self.policy = policy
        self.queue = queue
        self.reportError = reportError
        self.appliedFPS = max(options.adaptiveActiveFPS, options.adaptiveIdleFPS)
        self.requestedFPS = self.appliedFPS
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    func invalidate() {
        active = false
        timer?.cancel()
        timer = nil
    }

    /// Called after source frame classification and when mouse activity arrives.
    /// Mouse events wake a low-rate source without waiting for its next idle frame.
    func refresh() {
        guard active else { return }
        requestedFPS = policy.desiredFrameRate(at: CMClockGetTime(CMClockGetHostTimeClock()))
        guard requestedFPS != appliedFPS, !updating else { return }
        updating = true
        let rate = requestedFPS
        configuration.minimumFrameInterval = CMTime(seconds: 1 / rate, preferredTimescale: 600_000)
        Task {
            var failure: Error?
            do { try await stream.updateConfiguration(configuration) }
            catch { failure = error }
            let updateFailure = failure
            queue.async { [self] in
                updating = false
                guard active else { return }
                if let error = updateFailure {
                    // The sampling policy still enforces the requested encoded cadence.
                    // Do not repeatedly hammer a stream that rejected an update.
                    reportError(error)
                    appliedFPS = rate
                } else { appliedFPS = rate }
                if requestedFPS != appliedFPS { refresh() }
            }
        }
    }
}
