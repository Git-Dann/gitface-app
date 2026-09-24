@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os

/// Writes composited frames and microphone audio to a movie file.
///
/// All mutable state lives behind `queue`. Video frames arrive from the render
/// thread and audio from ARKit's delegate queue, so nothing here may assume the
/// main actor, and nothing may block its caller.
///
/// `@unchecked Sendable` is load-bearing rather than a silencer: every stored
/// property is either confined to `queue` or is itself a lock. Adding a
/// property that is read or written outside `queue` breaks that invariant, and
/// the compiler will not catch it.
final class VideoRecorder: @unchecked Sendable {

    enum Failure: LocalizedError {
        case alreadyRecording
        case notRecording
        case setupFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "Already recording."
            case .notRecording:     "Not recording."
            case .setupFailed:      "Couldn't start the recorder."
            case .writeFailed(let why): "Recording failed: \(why)"
            }
        }
    }

    /// Hard cap on clip length. Camera, Neural Engine, Metal and HEVC encode
    /// are a sustained three-subsystem load, and a lens clip is short anyway.
    static let maximumDuration: TimeInterval = 60

    private let queue = DispatchQueue(label: "co.gitwork.facetrkr.recorder")
    private let activeFlag = OSAllocatedUnfairLock(initialState: false)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStart: CMTime?
    private var outputURL: URL?

    /// Safe to read from any thread, including the render thread.
    var isRecording: Bool { activeFlag.withLock { $0 } }

    // MARK: - Lifecycle

    func start(width: Int, height: Int, frameRate: Int = 60) throws -> URL {
        try queue.sync {
            guard writer == nil else { throw Failure.alreadyRecording }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("facetrkr-\(UUID().uuidString.prefix(8)).mov")
            try? FileManager.default.removeItem(at: url)

            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
                throw Failure.setupFailed
            }

            let videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: Self.videoSettings(width: width, height: height, frameRate: frameRate)
            )
            videoInput.expectsMediaDataInRealTime = true

            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.audioSettings
            )
            audioInput.expectsMediaDataInRealTime = true

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )

            guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                throw Failure.setupFailed
            }
            writer.add(videoInput)
            writer.add(audioInput)

            guard writer.startWriting() else {
                throw Failure.writeFailed(writer.error?.localizedDescription ?? "couldn't start writing")
            }

            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
            self.outputURL = url
            self.sessionStart = nil
            activeFlag.withLock { $0 = true }

            return url
        }
    }

    func finish() async throws -> URL {
        activeFlag.withLock { $0 = false }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let writer, let url = outputURL else {
                    continuation.resume(throwing: Failure.notRecording)
                    return
                }

                videoInput?.markAsFinished()
                audioInput?.markAsFinished()

                writer.finishWriting { [self] in
                    queue.async { [self] in
                        let status = writer.status
                        let error = writer.error
                        reset()

                        if status == .completed {
                            continuation.resume(returning: url)
                        } else {
                            continuation.resume(
                                throwing: Failure.writeFailed(error?.localizedDescription ?? "unknown")
                            )
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        activeFlag.withLock { $0 = false }
        queue.async { [self] in
            writer?.cancelWriting()
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
            reset()
        }
    }

    private func reset() {
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        sessionStart = nil
        outputURL = nil
    }

    // MARK: - Appending

    /// Called from the render thread's command buffer completion handler.
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        queue.async { [self] in
            guard let writer, let videoInput, let adaptor, writer.status == .writing else { return }

            // The session starts on the first video frame, and audio earlier
            // than that is dropped, so both tracks share one origin.
            if sessionStart == nil {
                sessionStart = time
                writer.startSession(atSourceTime: time)
            }

            // Drop rather than block. Falling behind the encoder must never
            // stall the render thread that feeds it.
            guard videoInput.isReadyForMoreMediaData else { return }
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
    }

    /// Called from ARKit's delegate queue.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            guard let writer, let audioInput, writer.status == .writing else { return }
            guard let sessionStart else { return }

            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard time >= sessionStart, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        }
    }

    // MARK: - Settings

    private static func videoSettings(width: Int, height: Int, frameRate: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate
            ],
            // Tagged explicitly. Leaving colour ambiguous is what produces the
            // classic washed-out AR recording.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
    }

    private static var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 96_000
        ]
    }
}
