import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum SplitAudio: Hashable {
    case all
    case take(Int) // 0-based
}

// MARK: - Instruction

/// A piece of text burned into the split, in Core Image coordinates.
struct SplitOverlay {
    let image: CIImage
    let end: Double?
}

/// Tells the compositor which take shows in which zone, where the lines are and how soft they are.
final class SplitInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let trackIDs: [CMPersistentTrackID]
    /// Per take: maps the source frame into the 1080x1920 canvas (Core Image coordinates).
    let transforms: [CGAffineTransform]
    /// Line positions, 0...1 from the left edge.
    let dividers: [CGFloat]
    /// Feather width in output pixels.
    let feather: CGFloat
    let overlays: [SplitOverlay]

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], transforms: [CGAffineTransform], dividers: [CGFloat], feather: CGFloat, overlays: [SplitOverlay] = []) {
        self.timeRange = timeRange
        self.trackIDs = trackIDs
        self.transforms = transforms
        self.dividers = dividers
        self.feather = feather
        self.overlays = overlays
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        super.init()
    }
}

// MARK: - Compositor

/// Blends the takes side by side with a feathered (soft) edge at each line.
final class SplitCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pixelFormat: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    var sourcePixelBufferAttributes: [String: Any]? { pixelFormat }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { pixelFormat }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? SplitInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "CutFlow", code: 1))
            return
        }

        let size = request.renderContext.size
        let canvas = CGRect(origin: .zero, size: size)
        var result = CIImage(color: .black).cropped(to: canvas)
        let feather = max(0.5, instruction.feather)

        for (i, trackID) in instruction.trackIDs.enumerated() {
            guard let buffer = request.sourceFrame(byTrackID: trackID) else { continue }
            let frame = CIImage(cvPixelBuffer: buffer)
                .transformed(by: instruction.transforms[i])
                .cropped(to: canvas)

            if i == 0 {
                // First take fills everything; the others are laid on top from their line rightwards.
                result = frame.composited(over: result)
            } else {
                let x = instruction.dividers[i - 1] * size.width
                let gradient = CIFilter.linearGradient()
                gradient.point0 = CGPoint(x: x - feather / 2, y: 0)
                gradient.point1 = CGPoint(x: x + feather / 2, y: 0)
                gradient.color0 = CIColor.black
                gradient.color1 = CIColor.white
                guard let mask = gradient.outputImage?.cropped(to: canvas) else { continue }
                result = frame.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: result,
                    kCIInputMaskImageKey: mask
                ])
            }
        }

        let now = request.compositionTime.seconds
        for overlay in instruction.overlays where overlay.end == nil || now < overlay.end! {
            result = overlay.image.composited(over: result)
        }

        context.render(result, to: output, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }
}

// MARK: - Building

enum SplitEditor {
    static let renderSize = CGSize(width: 1080, height: 1920)

    /// Flips between AVFoundation's top-left and Core Image's bottom-left coordinates.
    static func flip(height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }

    static func build(takes: [URL], dividers: [CGFloat], feather: Double, audio: SplitAudio, texts: [TextItem] = []) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        let composition = AVMutableComposition()

        // Load every take and use the shortest length so all zones stay filled.
        var sources: [(video: AVAssetTrack, audio: AVAssetTrack?, natural: CGSize, preferred: CGAffineTransform)] = []
        var shortest = CMTime.positiveInfinity
        for url in takes {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw EditorError.noVideo }
            let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
            let duration = try await asset.load(.duration)
            let (natural, preferred) = try await video.load(.naturalSize, .preferredTransform)
            sources.append((video, audioTrack, natural, preferred))
            shortest = CMTimeMinimum(shortest, duration)
        }
        guard shortest.isNumeric, shortest.seconds > 0.2 else { throw EditorError.noVideo }
        let range = CMTimeRange(start: .zero, duration: shortest)

        var trackIDs: [CMPersistentTrackID] = []
        var transforms: [CGAffineTransform] = []
        for (i, source) in sources.enumerated() {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw EditorError.noVideo
            }
            try track.insertTimeRange(range, of: source.video, at: .zero)
            trackIDs.append(track.trackID)

            let fillAV = AutoEditor.fillTransform(natural: source.natural, preferred: source.preferred)
            let fillCI = flip(height: source.natural.height)
                .concatenating(fillAV)
                .concatenating(flip(height: renderSize.height))
            transforms.append(fillCI)

            let wantsAudio: Bool
            switch audio {
            case .all: wantsAudio = true
            case .take(let n): wantsAudio = n == i
            }
            if wantsAudio, let sourceAudio = source.audio,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
            }
        }

        let overlays: [SplitOverlay] = await MainActor.run {
            texts.compactMap { item in
                guard let img = TextRenderer.image(for: item), let cg = img.cgImage else { return nil }
                let f = TextRenderer.frame(for: img.size, y: item.y)
                // Core Image counts y from the bottom
                let placed = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: f.minX, y: renderSize.height - f.maxY))
                return SplitOverlay(image: placed, end: item.timing.end)
            }
        }

        let scale = renderSize.width / 1080
        let instruction = SplitInstruction(
            timeRange: range,
            trackIDs: trackIDs,
            transforms: transforms,
            dividers: dividers,
            feather: CGFloat(feather) * scale,
            overlays: overlays
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = SplitCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        return (composition, videoComposition)
    }

    static func export(composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, to url: URL,
                       progress: (@MainActor (Double) -> Void)? = nil) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw EditorError.exportFailed
        }
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true
        let ticker = Task {
            while !Task.isCancelled {
                let value = Double(session.progress)
                await progress?(value)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        ticker.cancel()
        if session.status != .completed {
            throw session.error ?? EditorError.exportFailed
        }
    }
}
