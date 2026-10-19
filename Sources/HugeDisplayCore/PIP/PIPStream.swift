import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Boxes a non-Sendable sample buffer for the hop from the capture queue to the main thread.
private struct SampleBox: @unchecked Sendable { let buffer: CMSampleBuffer }

/// Lock-protected single latest-frame slot plus a "drain pending" flag.
private final class FrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (Int, SampleBox)?
    private var drainPending = false

    /// Stores the frame (replacing any older one). Returns true when the caller must schedule a drain.
    func store(_ gen: Int, _ box: SampleBox) -> Bool {
        lock.lock(); defer { lock.unlock() }
        latest = (gen, box)
        if drainPending { return false }
        drainPending = true
        return true
    }

    func take() -> (Int, SampleBox)? {
        lock.lock(); defer { lock.unlock() }
        drainPending = false
        defer { latest = nil }
        return latest
    }
}

/// Receives SCStream callbacks on the capture queue and forwards complete frames to the main thread.
private final class PIPStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let generation: Int
    let onFrame: @Sendable (Int, SampleBox) -> Void
    let onStop: @Sendable (Int, Error) -> Void

    init(generation: Int, onFrame: @escaping @Sendable (Int, SampleBox) -> Void, onStop: @escaping @Sendable (Int, Error) -> Void) {
        self.generation = generation
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer) else { return }
        onFrame(generation, SampleBox(buffer: sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(generation, error)
    }

    /// SCK also delivers .idle/.blank/.suspended frames with no new pixels; only .complete ones are drawn.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}

/// One SCStream with start/stop/resize handled serially. The SCStream instance is recreated on each
/// resume (cheap), but resizes use `updateConfiguration` on the live stream.
@MainActor
final class PIPStream {
    private let filter: SCContentFilter
    private var configuration: SCStreamConfiguration
    private let queue = DispatchQueue(label: "hugedisplay.pip.capture", qos: .userInteractive)

    private var stream: SCStream?
    private var output: PIPStreamOutput?
    private var generation = 0
    private var wantsRunning = false
    private var isRunning = false
    private var worker: Task<Void, Never>?
    private var isShutDown = false
    private nonisolated let slot = FrameSlot()

    private let onFrame: @MainActor (CMSampleBuffer) -> Void
    private let onStop: @MainActor (Error) -> Void

    init(filter: SCContentFilter, width: Int, height: Int, onFrame: @escaping @MainActor (CMSampleBuffer) -> Void, onStop: @escaping @MainActor (Error) -> Void) {
        self.filter = filter
        self.onFrame = onFrame
        self.onStop = onStop
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        configuration = config
    }

    /// Starts or pauses capture. Safe to call repeatedly; operations are serialized.
    func setActive(_ active: Bool) {
        guard !isShutDown else { return }
        wantsRunning = active
        reconcile()
    }

    /// Applies a new output size without recreating the stream.
    func updateSize(width: Int, height: Int) {
        guard configuration.width != width || configuration.height != height else { return }
        let updated = (configuration.copy() as? SCStreamConfiguration) ?? configuration
        updated.width = width
        updated.height = height
        configuration = updated
        guard let stream, isRunning else { return } // paused: the new size is used on next start
        Task { try? await stream.updateConfiguration(updated) }
    }

    func shutdown() {
        isShutDown = true
        wantsRunning = false
        reconcile()
    }

    // MARK: - Private

    private func reconcile() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, self.isRunning != self.wantsRunning {
                let target = self.wantsRunning
                if target {
                    do {
                        try await self.startStream()
                    } catch {
                        self.wantsRunning = false
                        self.stream = nil
                        self.output = nil
                        self.generation += 1
                        if !self.isShutDown { self.onStop(error) }
                        break
                    }
                } else {
                    await self.stopStream()
                }
                self.isRunning = target
            }
            self?.worker = nil
        }
    }

    private func startStream() async throws {
        generation += 1
        let gen = generation
        let handler = PIPStreamOutput(
            generation: gen,
            onFrame: { [weak self] gen, box in
                guard let slot = self?.slot else { return }
                // Latest-frame slot: older undelivered frames are dropped; at most one main-thread drain in flight.
                if slot.store(gen, box) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.drain() } }
                }
            },
            onStop: { [weak self] gen, error in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamDied(error, generation: gen) } }
            }
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: handler)
        try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        output = handler
    }

    private func stopStream() async {
        generation += 1 // drop frames still in flight from the old stream
        let old = stream
        stream = nil
        output = nil
        try? await old?.stopCapture()
    }

    private func drain() {
        guard let (gen, box) = slot.take() else { return }
        deliver(box.buffer, generation: gen)
    }

    private func deliver(_ buffer: CMSampleBuffer, generation gen: Int) {
        guard gen == generation else { return }
        onFrame(buffer)
    }

    private func streamDied(_ error: Error, generation gen: Int) {
        guard gen == generation, !isShutDown else { return }
        generation += 1
        stream = nil
        output = nil
        isRunning = false
        wantsRunning = false
        onStop(error)
    }
}
