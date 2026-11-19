import AVFoundation
import UIKit
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Models

struct Clip: Identifiable {
    let id = UUID()
    let url: URL
    let duration: Double
    let thumbnail: UIImage?
}

struct ClipInfo {
    let url: URL
    let duration: Double
    let slot: Int // 1...6
}

struct Segment: Identifiable {
    let id = UUID()
    let clipIndex: Int
    let start: Double
    var duration: Double
    let score: Double
}

enum Pace: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case medium = "Medium"
    case chill = "Chill"

    var id: String { rawValue }

    /// Pauses shorter than this are kept (not cut).
    var keepGap: Double {
        switch self {
        case .fast: return 0.22
        case .medium: return 0.4
        case .chill: return 0.7
        }
    }

    /// Breathing room left around each spoken part.
    var pad: Double {
        switch self {
        case .fast: return 0.06
        case .medium: return 0.1
        case .chill: return 0.16
        }
    }
}

enum RoomLevel: String, CaseIterable, Identifiable {
    case quiet = "Quiet"
    case normal = "Normal"
    case noisy = "Noisy"

    var id: String { rawValue }

    /// How far above the background noise counts as talking.
    var factor: Double {
        switch self {
        case .quiet: return 0.10
        case .normal: return 0.18
        case .noisy: return 0.30
        }
    }
}

struct EditSettings {
    let target: Double
    let pace: Pace
    let hookFirst: Bool
    let smoothCuts: Bool
    var cutReaches = true
    let removeSilences: Bool
    let room: RoomLevel
    let reroll: Bool
}

struct EditResult: Identifiable {
    let id = UUID()
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let segments: [Segment]
    let duration: Double
}

enum EditorError: LocalizedError {
    case noVideo
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noVideo: return "None of the clips had usable video."
        case .exportFailed: return "The export didn't finish."
        }
    }
}

/// Lets PhotosPicker hand us a video file we can keep.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

// MARK: - Auto editor

enum AutoEditor {
    static let renderSize = CGSize(width: 1080, height: 1920)
    static let window = 0.1 // seconds per loudness sample

    static func thumbnail(for asset: AVAsset, maxSize: CGFloat = 300) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        if let result = try? await gen.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)) {
            return UIImage(cgImage: result.image)
        }
        return nil
    }

    /// Loudness (RMS) of the clip's audio, one value per 0.1s.
    static func loudness(url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }

        let sampleRate = 8000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let perWindow = Int(sampleRate * window)
        var result: [Float] = []
        var acc: Double = 0
        var count = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 1 else { continue }
            var samples = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: (length / 2) * 2, destination: &samples)
            for s in samples {
                let v = Double(s) / 32768.0
                acc += v * v
                count += 1
                if count == perWindow {
                    result.append(Float((acc / Double(count)).squareRoot()))
                    acc = 0
                    count = 0
                }
            }
        }
        return result
    }

    typealias Region = (start: Double, end: Double, score: Double)

    static func meanEnergy(_ e: ArraySlice<Float>) -> Double {
        e.isEmpty ? 0 : Double(e.reduce(0, +)) / Double(e.count)
    }

    /// Finds the parts of a clip where someone is talking and drops the silences.
    static func speechRegions(energy: [Float], usable: Double, settings: EditSettings) -> [Region] {
        let whole: [Region] = [(start: 0, end: usable, score: meanEnergy(energy[...]))]
        guard settings.removeSilences, energy.count > 5 else { return whole }

        let sorted = energy.sorted()
        let floor = Double(sorted[Int(Double(sorted.count - 1) * 0.10)])
        let peak = Double(sorted[Int(Double(sorted.count - 1) * 0.95)])
        guard peak > 0.003, peak > floor * 1.5 else { return whole }
        let threshold = max(0.003, floor + (peak - floor) * settings.room.factor)

        // 1. Raw loud/talking stretches
        var raw: [(start: Double, end: Double)] = []
        var openAt: Int? = nil
        for (i, e) in energy.enumerated() {
            if Double(e) > threshold {
                if openAt == nil { openAt = i }
            } else if let o = openAt {
                raw.append((start: Double(o) * window, end: Double(i) * window))
                openAt = nil
            }
        }
        if let o = openAt { raw.append((start: Double(o) * window, end: Double(energy.count) * window)) }

        // 2. Keep short natural pauses (merge across them)
        var merged: [(start: Double, end: Double)] = []
        for r in raw {
            if let last = merged.last, r.start - last.end < settings.pace.keepGap {
                merged[merged.count - 1] = (start: last.start, end: r.end)
            } else {
                merged.append(r)
            }
        }

        // 3. Drop tiny blips, add breathing room, clamp
        var padded: [(start: Double, end: Double)] = []
        for r in merged where r.end - r.start >= 0.2 {
            let st = max(0, r.start - settings.pace.pad)
            let en = min(usable, r.end + settings.pace.pad)
            guard en - st > 0.15 else { continue }
            if let last = padded.last, st <= last.end {
                padded[padded.count - 1] = (start: last.start, end: max(last.end, en))
            } else {
                padded.append((start: st, end: en))
            }
        }
        guard !padded.isEmpty else { return whole }

        return padded.map { r in
            let a = min(energy.count - 1, Int(r.start / window))
            let b = min(energy.count, max(a + 1, Int(r.end / window)))
            return (start: r.start, end: r.end, score: meanEnergy(energy[a..<b]))
        }
    }

    // MARK: Reaching for the phone

    /// Finds the start and end of a clip where you reach for the phone to tap record or stop.
    /// A hand over the lens makes the picture look completely different from the rest of the clip,
    /// far more than talking or gesturing does. We compare the first and last couple of seconds with a
    /// normal frame and cut past the part where the hand is in shot.
    /// The very first and last split second (the tap itself) are always trimmed.
    static func reachTrim(url: URL, duration: Double) async -> (start: Double, end: Double) {
        let plainStart = min(0.15, duration / 4)
        let plainEnd = max(plainStart, duration - min(0.25, duration / 4))
        guard duration > 2 else { return (plainStart, plainEnd) }

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 96, height: 96)
        let tolerance = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        func frame(_ t: Double) async -> [UInt8]? {
            let time = CMTime(seconds: min(max(0, t), duration - 0.05), preferredTimescale: 600)
            guard let img = try? await gen.image(at: time).image else { return nil }
            return grayPixels(img)
        }
        func distances(_ times: [Double], to ref: [UInt8]) async -> [Double] {
            var out: [Double] = []
            for t in times {
                if let f = await frame(t), f.count == ref.count { out.append(frameChange(f, ref)) } else { out.append(0) }
            }
            return out
        }

        let step = 0.1
        let window = min(2.5, duration / 3)

        // How different normal frames look from each other, measured in the middle of the clip
        let mid = duration / 2
        guard let midRef = await frame(mid + window / 2) else { return (plainStart, plainEnd) }
        let baseline = await distances(Array(stride(from: mid - window / 2, to: mid + window / 2, by: step * 2)), to: midRef).sorted()
        let typical = baseline.isEmpty ? 0.02 : baseline[min(baseline.count - 1, Int(Double(baseline.count) * 0.75))]
        let threshold = max(0.05, typical * 2.5)

        var start = plainStart
        let startTimes = Array(stride(from: 0.0, through: window, by: step))
        if startTimes.count > 2, let ref = await frame(window) {
            let d = await distances(startTimes, to: ref)
            if d[0] > threshold || d[1] > threshold {          // hand in shot right at the start
                var i = 0
                while i + 1 < d.count && (d[i] > threshold || d[i + 1] > threshold) { i += 1 }
                start = max(start, startTimes[i] + 0.3)         // a moment after it's gone
            }
        }

        var end = plainEnd
        let endTimes = Array(stride(from: duration - window, through: duration - 0.05, by: step))
        if endTimes.count > 2, let ref = await frame(endTimes[0]) {
            let d = await distances(endTimes, to: ref)
            let n = d.count
            if d[n - 1] > threshold || d[n - 2] > threshold {  // hand in shot right at the end
                var j = n - 1
                while j - 1 >= 0 && (d[j] > threshold || d[j - 1] > threshold) { j -= 1 }
                end = min(end, endTimes[j] - 0.15)              // a moment before it comes in
            }
        }

        // If that would leave almost nothing, it wasn't a reach: keep the plain trim
        if end - start < 0.6 { return (plainStart, plainEnd) }
        return (start, end)
    }

    /// A tiny 40x40 grayscale copy of a frame, for comparing frames quickly.
    static func grayPixels(_ image: CGImage) -> [UInt8]? {
        let w = 40, h = 40
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? pixels : nil
    }

    /// Average change between two frames, 0 (same) to 1 (completely different).
    static func frameChange(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        for i in a.indices { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count) / 255
    }

    /// When someone is talking in a take, with short pauses merged (used by the script prompter).
    static func voiceRegions(url: URL, room: RoomLevel = .normal) async -> [ClosedRange<Double>] {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let energy = await loudness(url: url)
        guard duration > 0.3, !energy.isEmpty else { return [] }
        let settings = EditSettings(target: 9999, pace: .fast, hookFirst: false, smoothCuts: false,
                                    removeSilences: true, room: room, reroll: false)
        let regions = speechRegions(energy: energy, usable: duration, settings: settings)
        // A single region covering the whole clip means we couldn't tell talking from quiet.
        if regions.count == 1, regions[0].start <= 0.01, regions[0].end >= duration - 0.01 { return [] }
        var merged: [ClosedRange<Double>] = []
        for r in regions {
            if let last = merged.last, r.start - last.upperBound < 0.9 {
                merged[merged.count - 1] = last.lowerBound...r.end
            } else {
                merged.append(r.start...r.end)
            }
        }
        return merged
    }

    /// Builds the edit: clips in slot order (1 → 6) with silences removed,
    /// an optional hook teaser up front, capped at the chosen length.
    static func pickSegments(clips: [ClipInfo], settings: EditSettings) async -> [Segment] {
        var body: [Segment] = []
        for (i, clip) in clips.enumerated() {
            let usable = max(0, clip.duration - 0.1)
            guard usable > 0.3 else { continue }
            // Cut where you reach for the phone to start or stop recording
            var lo = 0.0, hi = usable
            if settings.cutReaches {
                let reach = await reachTrim(url: clip.url, duration: clip.duration)
                lo = reach.start
                hi = min(usable, reach.end)
            }
            let energy = await loudness(url: clip.url)
            for r in speechRegions(energy: energy, usable: usable, settings: settings) {
                let st = max(r.start, lo)
                let en = min(r.end, hi)
                guard en - st >= 0.2 else { continue }
                let jitter = settings.reroll ? Double.random(in: 0...0.03) : 0
                body.append(Segment(clipIndex: i, start: st, duration: en - st, score: r.score + jitter))
            }
        }
        guard !body.isEmpty else { return [] }

        // Hook teaser: the strongest moment from clips 2-6 plays first (max 2.5s).
        var hook: Segment? = nil
        if settings.hookFirst && clips.count > 1 {
            let pool = body.filter { $0.clipIndex > 0 }.sorted { $0.score > $1.score }
            let choice = settings.reroll ? pool.prefix(3).randomElement() : pool.first
            if let c = choice {
                hook = Segment(clipIndex: c.clipIndex, start: c.start, duration: min(c.duration, 2.5), score: c.score)
            }
        }

        // Fit the length: drop the weakest parts (never the very first line).
        let budget = settings.target - (hook?.duration ?? 0)
        // Smooth cuts add a little room around each part (about one blend each), so count that in
        let perPart = settings.smoothCuts ? 0.15 : 0
        func length(_ total: Double) -> Double { total + Double(body.count + (hook == nil ? 0 : 1)) * perPart }
        var total = body.reduce(0) { $0 + $1.duration }
        while length(total) > budget, body.count > 1 {
            guard let weakest = body.enumerated().dropFirst().min(by: { $0.element.score < $1.element.score }) else { break }
            let over = length(total) - budget
            // Dropping a long part to fix a small overrun would leave the edit well short: trim the end instead
            if weakest.element.duration - perPart > over + 2 { break }
            total -= weakest.element.duration
            body.remove(at: weakest.offset)
        }
        if length(total) > budget, var last = body.last {
            last.duration = max(0.3, last.duration - (length(total) - budget))
            body[body.count - 1] = last
        }

        if let hook { return [hook] + body }
        return body
    }

    // MARK: Smooth cuts

    /// One piece of the timeline, in ticks of 1/600 s so every boundary lines up exactly.
    struct Placed {
        let segment: Segment
        let srcStart: Int64      // where it starts in its source clip
        let length: Int64        // how long it plays
        let at: Int64            // where it starts in the edit
        let blendIn: Int64       // overlap with the piece before (crossfade)
        var blendOut: Int64 = 0  // overlap with the piece after
        var track: Int { index % 2 }
        let index: Int
    }

    static let ticks: Int64 = 600

    /// Lays the segments out with short overlaps so every cut is a quick crossfade (no jump cuts).
    /// Each segment is widened by one blend on both sides, taken from the pause around it,
    /// so the fade only ever covers the pause and never the start or end of a word.
    static func planTimeline(segments: [Segment], clipDurations: [Double], blend: Double) -> [Placed] {
        func tk(_ s: Double) -> Int64 { Int64((s * Double(ticks)).rounded()) }
        let pad = blend
        var widened: [(seg: Segment, start: Int64, length: Int64)] = []
        for seg in segments {
            let clipLen = clipDurations.indices.contains(seg.clipIndex) ? clipDurations[seg.clipIndex] : seg.start + seg.duration
            let st = max(0, seg.start - pad)
            let en = min(clipLen - 0.02, seg.start + seg.duration + pad)   // never past the end of the clip
            let length = tk(en) - tk(st)
            guard length > tk(0.1) else { continue }
            widened.append((seg, tk(st), length))
        }
        var out: [Placed] = []
        var cursor: Int64 = 0
        for (i, w) in widened.enumerated() {
            var overlap: Int64 = 0
            if i > 0 {
                // Never let a blend take more than a third of either piece
                overlap = min(tk(blend), widened[i - 1].length / 3, w.length / 3)
                out[i - 1].blendOut = overlap
            }
            let at = cursor - overlap
            out.append(Placed(segment: w.seg, srcStart: w.start, length: w.length, at: at, blendIn: overlap, index: i))
            cursor = at + w.length
        }
        return out
    }

    /// Stitches the segments into one vertical 9:16 video with smooth crossfades between cuts.
    static func build(clips: [ClipInfo], segments: [Segment], settings: EditSettings) async throws -> EditResult {
        // Load each clip's tracks once
        struct Source { let video: AVAssetTrack; let audio: AVAssetTrack?; let fill: CGAffineTransform; let length: Double }
        var sources: [Int: Source] = [:]
        for index in Set(segments.map(\.clipIndex)) where clips.indices.contains(index) {
            let asset = AVURLAsset(url: clips[index].url)
            guard let video = try? await asset.loadTracks(withMediaType: .video).first,
                  let props = try? await video.load(.naturalSize, .preferredTransform) else { continue }
            let (natural, preferred) = props
            let audio = try? await asset.loadTracks(withMediaType: .audio).first
            // The picture can end a little before the sound, so cuts are kept inside the video track
            let videoRange = try? await video.load(.timeRange)
            let length = min(clips[index].duration, videoRange.map { $0.end.seconds } ?? clips[index].duration)
            sources[index] = Source(video: video, audio: audio,
                                    fill: fillTransform(natural: natural, preferred: preferred), length: length)
        }
        let usable = segments.filter { sources[$0.clipIndex] != nil }
        let lengths = clips.indices.map { sources[$0]?.length ?? clips[$0].duration }
        let plan = planTimeline(segments: usable, clipDurations: lengths,
                                blend: settings.smoothCuts ? 0.15 : 0)
        guard !plan.isEmpty else { throw EditorError.noVideo }

        let composition = AVMutableComposition()
        var videoTracks: [AVMutableCompositionTrack] = []
        var audioTracks: [AVMutableCompositionTrack] = []
        for _ in 0..<2 {
            guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw EditorError.noVideo
            }
            videoTracks.append(v)
            audioTracks.append(a)
        }

        func t(_ v: Int64) -> CMTime { CMTime(value: v, timescale: CMTimeScale(ticks)) }
        func range(_ start: Int64, _ length: Int64) -> CMTimeRange { CMTimeRange(start: t(start), duration: t(length)) }

        var placed: [Placed] = []
        for piece in plan {
            guard let src = sources[piece.segment.clipIndex] else { continue }
            let srcRange = range(piece.srcStart, piece.length)
            do {
                try videoTracks[piece.track].insertTimeRange(srcRange, of: src.video, at: t(piece.at))
            } catch {
                throw EditorError.noVideo
            }
            if let audio = src.audio {
                try? audioTracks[piece.track].insertTimeRange(srcRange, of: audio, at: t(piece.at))
            }
            placed.append(piece)
        }

        // Drop tracks that ended up empty (one-piece edits, clips with no sound): some iPhones
        // refuse to export a composition with an empty track in it.
        for track in videoTracks + audioTracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }
        let liveAudio = audioTracks.filter { !$0.segments.isEmpty }

        // Video: a plain stretch for each piece, and a crossfade wherever two pieces overlap
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (i, piece) in placed.enumerated() {
            let fill = sources[piece.segment.clipIndex]!.fill
            if piece.blendIn > 0, i > 0 {
                let prev = placed[i - 1]
                let blendRange = range(piece.at, piece.blendIn)
                let outgoing = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[prev.track])
                outgoing.setTransform(sources[prev.segment.clipIndex]!.fill, at: blendRange.start)
                outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: blendRange)
                let incoming = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[piece.track])
                incoming.setTransform(fill, at: blendRange.start)
                let blend = AVMutableVideoCompositionInstruction()
                blend.timeRange = blendRange
                blend.layerInstructions = [outgoing, incoming] // first one is drawn on top
                instructions.append(blend)
            }
            let plainStart = piece.at + piece.blendIn
            let plainLength = piece.length - piece.blendIn - piece.blendOut
            if plainLength > 0 {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[piece.track])
                layer.setTransform(fill, at: t(plainStart))
                let plain = AVMutableVideoCompositionInstruction()
                plain.timeRange = range(plainStart, plainLength)
                plain.layerInstructions = [layer]
                instructions.append(plain)
            }
        }

        // Audio: the same overlaps, faded so words never click or pop at a cut
        let params = audioTracks.map { track -> AVMutableAudioMixInputParameters in
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(1, at: .zero)
            return p
        }
        for (i, piece) in placed.enumerated() {
            if piece.blendIn > 0, i > 0 {
                let r = range(piece.at, piece.blendIn)
                params[placed[i - 1].track].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: r)
                params[piece.track].setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: r)
            } else {
                params[piece.track].setVolume(1, at: t(piece.at))
            }
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = params.enumerated()
            .filter { liveAudio.contains(audioTracks[$0.offset]) }
            .map(\.element)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        let end = placed.last.map { $0.at + $0.length } ?? 0
        return EditResult(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                          segments: placed.map(\.segment), duration: t(end).seconds)
    }

    /// Burns the text into the export (the in-app preview draws it on top instead).
    @MainActor
    static func withText(_ base: AVMutableVideoComposition, texts: [TextItem]) -> AVMutableVideoComposition {
        guard !texts.isEmpty, let composition = base.mutableCopy() as? AVMutableVideoComposition else { return base }
        let size = renderSize
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        for item in texts {
            guard let img = TextRenderer.image(for: item), let cg = img.cgImage else { continue }
            let f = TextRenderer.frame(for: img.size, y: item.y)
            let layer = CALayer()
            layer.contents = cg
            layer.contentsGravity = .resize
            // Core Animation export counts y from the bottom
            layer.frame = CGRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
            if let end = item.timing.end {
                layer.opacity = 0
                let show = CABasicAnimation(keyPath: "opacity")
                show.fromValue = 1
                show.toValue = 1
                show.beginTime = AVCoreAnimationBeginTimeAtZero
                show.duration = end
                show.isRemovedOnCompletion = false
                layer.add(show, forKey: "show")
            }
            parent.addSublayer(layer)
        }
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        return composition
    }

    /// Scale-to-fill crop into 1080x1920, centered, respecting phone rotation.
    static func fillTransform(natural: CGSize, preferred: CGAffineTransform) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let oriented = CGSize(width: abs(rect.width), height: abs(rect.height))
        guard oriented.width > 0, oriented.height > 0 else { return preferred }
        let scale = max(renderSize.width / oriented.width, renderSize.height / oriented.height)
        return preferred
            .concatenating(CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (renderSize.width - oriented.width * scale) / 2,
                y: (renderSize.height - oriented.height * scale) / 2))
    }

    static func zoomed(_ t: CGAffineTransform, by factor: CGFloat) -> CGAffineTransform {
        let cx = renderSize.width / 2
        let cy = renderSize.height / 2
        return t
            .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
    }

    static func export(_ result: EditResult, to url: URL, texts: [TextItem] = []) async throws {
        guard let session = AVAssetExportSession(asset: result.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw EditorError.exportFailed
        }
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = await withText(result.videoComposition, texts: texts)
        session.audioMix = result.audioMix
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        if session.status != .completed {
            throw session.error ?? EditorError.exportFailed
        }
    }
}
