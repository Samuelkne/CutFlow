import SwiftUI
import AVKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import UIKit

// MARK: - Live settings shared with the camera thread

struct LiveConfig {
    var people = 2
    var dividers: [CGFloat] = [0.5]
    var feather: CGFloat = 40      // px at 1080 wide
    var activeZone = 0
    var players: [Int: TakePlayer] = [:]
    /// How see-through the takes you already filmed are while filming the next side (1 = solid).
    var ghost: CGFloat = 0.5

    func zoneRange(_ zone: Int) -> ClosedRange<CGFloat> {
        let lo = zone == 0 ? 0 : dividers[min(zone - 1, dividers.count - 1)]
        let hi = zone >= dividers.count ? 1 : dividers[zone]
        return lo...max(lo, hi)
    }
}

enum ZoneStatus: Equatable {
    case noPerson
    case inside
    case crossing(left: Bool)

    var isCrossing: Bool {
        if case .crossing = self { return true }
        return false
    }
}

enum LiveCanvas {
    static let size = CGSize(width: 540, height: 960) // half of 1080x1920, for a fast preview

    static func fill(from source: CGSize, to target: CGSize) -> CGAffineTransform {
        guard source.width > 0, source.height > 0 else { return .identity }
        let s = max(target.width / source.width, target.height / source.height)
        return CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: (target.width - source.width * s) / 2,
                                             y: (target.height - source.height * s) / 2))
    }
}

// MARK: - An earlier take, played in sync while you film the next one

final class TakePlayer {
    let url: URL
    let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let lock = NSLock()
    private var transform: CGAffineTransform = .identity
    private var firstFrame: CIImage?
    private var lastFrame: CIImage?

    init(url: URL) {
        self.url = url
        let item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true // so the mic doesn't record it
        player.actionAtItemEnd = .pause
    }

    func prepare() async {
        let asset = AVURLAsset(url: url)
        let canvas = LiveCanvas.size
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.naturalSize, .preferredTransform) {
            let (natural, preferred) = loaded
            let toCanvas = CGAffineTransform(scaleX: canvas.width / SplitEditor.renderSize.width,
                                             y: canvas.height / SplitEditor.renderSize.height)
            let t = SplitEditor.flip(height: natural.height)
                .concatenating(AutoEditor.fillTransform(natural: natural, preferred: preferred))
                .concatenating(SplitEditor.flip(height: SplitEditor.renderSize.height))
                .concatenating(toCanvas)
            lock.lock(); transform = t; lock.unlock()
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        if let result = try? await gen.image(at: .zero) {
            let img = CIImage(cgImage: result.image)
            let filled = img.transformed(by: LiveCanvas.fill(from: img.extent.size, to: canvas))
            lock.lock(); firstFrame = filled; lock.unlock()
        }
    }

    /// Call on the main thread when recording starts.
    func restart() {
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func reset() {
        player.pause()
        player.seek(to: .zero)
        lock.lock(); lastFrame = nil; lock.unlock()
    }

    /// Current frame, already placed on the preview canvas. Safe from any thread.
    func currentImage() -> CIImage? {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lock.lock()
            let img = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
            lastFrame = img
            lock.unlock()
            return img
        }
        lock.lock(); defer { lock.unlock() }
        return lastFrame ?? firstFrame
    }
}

// MARK: - Camera engine: records, shows the live blend, watches the line

final class CameraModel: NSObject, ObservableObject,
                         AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "cutflow.session")
    private let dataQueue = DispatchQueue(label: "cutflow.data")
    private let visionQueue = DispatchQueue(label: "cutflow.vision")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private var position: AVCaptureDevice.Position = .front

    weak var displayView: UIImageView?

    // Settings from the main thread
    private let lock = NSLock()
    private var storedConfig = LiveConfig()
    private var config: LiveConfig {
        lock.lock(); defer { lock.unlock() }
        return storedConfig
    }

    // Writer state (dataQueue only)
    private var wantsRecording = false
    private var writer: AVAssetWriter?
    private var writerVideo: AVAssetWriterInput?
    private var writerAudio: AVAssetWriterInput?
    private var sessionStarted = false
    private var visionBusy = false
    private var frameCount = 0

    @Published var isRecording = false
    @Published var recordedURL: URL?
    @Published var errorText: String?
    @Published var zoneStatus: ZoneStatus = .noPerson

    func update(_ newConfig: LiveConfig) {
        lock.lock(); storedConfig = newConfig; lock.unlock()
    }

    func start() async {
        let videoOK = await AVCaptureDevice.requestAccess(for: .video)
        let audioOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard videoOK else {
            await MainActor.run { self.errorText = "Allow camera access in Settings to film takes." }
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configure(audio: audioOK)
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configure(audio: Bool) {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        addCamera()
        if audio, let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        setUpConnection()
        session.commitConfiguration()
    }

    private func addCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        videoInput = input
    }

    /// Upright portrait frames; front camera mirrored so the zones match what you see.
    private func setUpConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
    }

    func flip() {
        guard !isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let current = self.videoInput { self.session.removeInput(current) }
            self.position = self.position == .front ? .back : .front
            self.addCamera()
            self.setUpConnection()
            self.session.commitConfiguration()
        }
    }

    // MARK: Recording

    /// Call on the main thread.
    func toggleRecording() {
        if isRecording {
            for p in config.players.values { p.player.pause() }
            dataQueue.async { [weak self] in
                self?.wantsRecording = false
                self?.finishWriting()
            }
        } else {
            isRecording = true
            for p in config.players.values { p.restart() }
            dataQueue.async { [weak self] in self?.wantsRecording = true }
        }
    }

    private func setUpWriter(width: Int, height: Int) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        video.expectsMediaDataInRealTime = true
        if w.canAdd(video) { w.add(video) }
        writerVideo = video

        if let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audio.expectsMediaDataInRealTime = true
            if w.canAdd(audio) { w.add(audio); writerAudio = audio }
        }
        w.startWriting()
        writer = w
    }

    private func finishWriting() {
        guard let w = writer else {
            DispatchQueue.main.async { self.isRecording = false }
            return
        }
        writer = nil
        sessionStarted = false
        writerVideo?.markAsFinished()
        writerAudio?.markAsFinished()
        writerVideo = nil
        writerAudio = nil
        let url = w.outputURL
        w.finishWriting { [weak self] in
            DispatchQueue.main.async {
                self?.isRecording = false
                if w.status == .completed {
                    self?.recordedURL = url
                } else {
                    self?.errorText = "Recording failed. Try again."
                }
            }
        }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if wantsRecording, sessionStarted, let audio = writerAudio, audio.isReadyForMoreMediaData {
            audio.append(sampleBuffer)
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let cfg = config

        if wantsRecording {
            if writer == nil {
                setUpWriter(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            }
            if let w = writer, w.status == .writing {
                if !sessionStarted {
                    w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    sessionStarted = true
                }
                if let video = writerVideo, video.isReadyForMoreMediaData { video.append(sampleBuffer) }
            }
        }

        // Live blend preview
        let blended = composite(live: CIImage(cvPixelBuffer: buffer), cfg: cfg)
        if let cg = ciContext.createCGImage(blended, from: CGRect(origin: .zero, size: LiveCanvas.size)) {
            let image = UIImage(cgImage: cg)
            DispatchQueue.main.async { [weak self] in self?.displayView?.image = image }
        }

        // Line detection a few times a second
        frameCount += 1
        if frameCount % 3 == 0, !visionBusy {
            visionBusy = true
            visionQueue.async { [weak self] in
                self?.detect(buffer, cfg: cfg)
                self?.dataQueue.async { self?.visionBusy = false }
            }
        }
    }

    /// Same feathered blend as the final export, at preview size.
    private func composite(live: CIImage, cfg: LiveConfig) -> CIImage {
        let canvasSize = LiveCanvas.size
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let liveFilled = live.transformed(by: LiveCanvas.fill(from: live.extent.size, to: canvasSize)).cropped(to: canvas)
        let feather = max(0.5, cfg.feather * canvasSize.width / 1080)
        var result = CIImage(color: .black).cropped(to: canvas)

        for zone in 0..<cfg.people {
            let content: CIImage
            if zone == cfg.activeZone {
                content = liveFilled
            } else if let earlier = cfg.players[zone]?.currentImage() {
                // Earlier take shown lighter, over the live camera, so you can line yourself up with it
                let faded = earlier.cropped(to: canvas).applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(max(cfg.ghost, 0), 1))
                ])
                content = faded.composited(over: liveFilled)
            } else {
                // Not filmed yet: show the camera, darkened
                content = liveFilled.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.3])
            }

            if zone == 0 {
                result = content.composited(over: result)
            } else {
                let x = cfg.dividers[zone - 1] * canvasSize.width
                let gradient = CIFilter.linearGradient()
                gradient.point0 = CGPoint(x: x - feather / 2, y: 0)
                gradient.point1 = CGPoint(x: x + feather / 2, y: 0)
                gradient.color0 = CIColor.black
                gradient.color1 = CIColor.white
                guard let mask = gradient.outputImage?.cropped(to: canvas) else { continue }
                result = content.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: result,
                    kCIInputMaskImageKey: mask
                ])
            }
        }
        return result.cropped(to: canvas)
    }

    /// Finds your body and checks whether any of it is outside your zone.
    private func detect(_ buffer: CVPixelBuffer, cfg: LiveConfig) {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        let zone = cfg.zoneRange(cfg.activeZone)
        let tolerance = cfg.feather / 1080 / 2 + 0.015
        var samples = 0, person = 0, overLeft = 0, overRight = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                samples += 1
                if pixels[y * rowBytes + x] > 127 {
                    person += 1
                    let nx = CGFloat(x) / CGFloat(width)
                    if nx < zone.lowerBound - tolerance { overLeft += 1 }
                    else if nx > zone.upperBound + tolerance { overRight += 1 }
                }
            }
        }

        let status: ZoneStatus
        if samples == 0 || Double(person) / Double(samples) < 0.01 {
            status = .noPerson
        } else if Double(overLeft + overRight) / Double(person) > 0.03 {
            status = .crossing(left: overLeft >= overRight)
        } else {
            status = .inside
        }
        DispatchQueue.main.async { [weak self] in
            if self?.zoneStatus != status { self?.zoneStatus = status }
        }
    }
}

struct LiveBlendView: UIViewRepresentable {
    let camera: CameraModel

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        camera.displayView = view
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        camera.displayView = uiView
    }
}

// MARK: - Guides

enum GuideLayout: String, CaseIterable, Identifiable {
    case split = "Zones"
    case grid = "Grid 3×3"
    case center = "Center"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .split: return "rectangle.split.3x1"
        case .grid: return "square.grid.3x3"
        case .center: return "plus"
        }
    }
}

struct GuideOverlay: View {
    @ObservedObject var split: SplitModel
    var activeZone: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let color = split.guideColor.opacity(split.guideOpacity)
            ZStack {
                switch split.layout {
                case .split:
                    // No lines here: the live blend shows the real feathered edge.
                    ForEach(0..<split.people, id: \.self) { zone in
                        let r = split.zoneRange(zone)
                        Text("\(zone + 1)")
                            .font(.headline.weight(.bold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(zone == activeZone || activeZone == nil ? RC.blue : Color.black.opacity(0.55))
                            .clipShape(Circle())
                            .position(x: (r.lowerBound + r.upperBound) / 2 * w, y: 40)
                    }
                case .grid:
                    Path { p in
                        for f in [1.0 / 3, 2.0 / 3] {
                            p.move(to: CGPoint(x: w * f, y: 0)); p.addLine(to: CGPoint(x: w * f, y: h))
                            p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f))
                        }
                    }
                    .stroke(color, lineWidth: 1.2)
                case .center:
                    Path { p in
                        p.move(to: CGPoint(x: w / 2 - 22, y: h / 2)); p.addLine(to: CGPoint(x: w / 2 + 22, y: h / 2))
                        p.move(to: CGPoint(x: w / 2, y: h / 2 - 22)); p.addLine(to: CGPoint(x: w / 2, y: h / 2 + 22))
                    }
                    .stroke(color, lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct GuideSettingsView: View {
    @ObservedObject var split: SplitModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            RC.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.headline).foregroundColor(.white)
                                .frame(width: 44, height: 44).background(RC.card).clipShape(Circle())
                        }
                        .accessibilityLabel("Close")
                        Spacer()
                        Text("Guides").font(.title3.bold()).foregroundColor(.white)
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Earlier take").font(.headline).foregroundColor(.white)
                            Spacer()
                            Text("\(Int(split.ghostOpacity * 100))%").font(.subheadline).monospacedDigit().foregroundColor(RC.dim)
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "circle.dotted").foregroundColor(RC.dim)
                            Slider(value: $split.ghostOpacity, in: 0.15...1).tint(RC.blue)
                                .accessibilityLabel("Earlier take opacity")
                            Image(systemName: "circle.fill").foregroundColor(RC.dim)
                        }
                        Text("While you film the next side, the side you already filmed shows see-through so you can line up with it. The export is always solid.")
                            .font(.caption).foregroundColor(RC.dim)
                    }

                    ToggleRow(icon: "eye", title: "Show Guides", isOn: $split.showGuides)

                    Text("Layout").font(.headline).foregroundColor(.white)
                    HStack(spacing: 10) {
                        ForEach(GuideLayout.allCases) { layout in
                            Button { split.layout = layout } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: layout.icon).font(.title2)
                                    Text(layout.rawValue).font(.caption)
                                }
                                .foregroundColor(split.layout == layout ? RC.blueBright : .white)
                                .frame(maxWidth: .infinity, minHeight: 76)
                                .rcCard(radius: 16)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(split.layout == layout ? RC.blueBright : .clear, lineWidth: 2))
                            }
                        }
                    }

                    Text("People").font(.headline).foregroundColor(.white)
                    HStack(spacing: 10) {
                        ForEach([2, 3], id: \.self) { n in
                            Button { split.setPeople(n) } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: n == 2 ? "person.2" : "person.3").font(.title2)
                                    Text("\(n) People").font(.caption)
                                }
                                .foregroundColor(split.people == n ? RC.blueBright : .white)
                                .frame(maxWidth: .infinity, minHeight: 76)
                                .rcCard(radius: 16)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(split.people == n ? RC.blueBright : .clear, lineWidth: 2))
                            }
                        }
                    }

                    HStack {
                        Text("Lines").font(.headline).foregroundColor(.white)
                        Spacer()
                        Button("Reset to default") { split.resetLines() }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(RC.blueBright)
                            .frame(minHeight: 44)
                    }
                    Text("Drag the lines on the Split screen to move them. Default is an even split.")
                        .font(.caption).foregroundColor(RC.dim)

                    Text("Line Style").font(.headline).foregroundColor(.white)
                    HStack(spacing: 10) {
                        Image(systemName: "circle.lefthalf.filled").foregroundColor(RC.dim)
                        Slider(value: $split.guideOpacity, in: 0.2...1).tint(RC.blue)
                    }
                    HStack(spacing: 14) {
                        ForEach(SplitModel.guideColors.indices, id: \.self) { i in
                            Button { split.guideColorIndex = i } label: {
                                Circle()
                                    .fill(SplitModel.guideColors[i])
                                    .frame(width: 34, height: 34)
                                    .overlay(Circle().stroke(Color.white, lineWidth: split.guideColorIndex == i ? 3 : 0).padding(-4))
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Line color \(i + 1)")
                        }
                    }
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Camera screen

struct CameraView: View {
    @ObservedObject var split: SplitModel
    @StateObject private var camera = CameraModel()
    /// Which side you're filming. Switch with the 1 / 2 / 3 buttons above the record button.
    @State private var take: Int
    @Environment(\.dismiss) private var dismiss
    @State private var showGuideSettings = false
    @State private var players: [Int: TakePlayer] = [:]
    @State private var pulse = false
    @State private var otherVoice: [ClosedRange<Double>]? = nil
    @State private var recordStart: Date?
    @State private var reviewURL: URL?
    @State private var reviewPlayer = AVPlayer()
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var discardNext = false

    private let haptics = UINotificationFeedbackGenerator()
    private let tick = UIImpactFeedbackGenerator(style: .medium)

    init(split: SplitModel, take: Int) {
        self.split = split
        _take = State(initialValue: take)
    }

    private var statusColor: Color {
        switch camera.zoneStatus {
        case .inside: return .green
        case .crossing: return .red
        case .noPerson: return .clear
        }
    }

    private var statusText: String {
        switch camera.zoneStatus {
        case .inside: return "You're in the \(mySide) side"
        case .crossing: return "You're over the line, move back"
        case .noPerson: return "Step into the \(mySide) side"
        }
    }

    private var sideNames: [String] {
        split.people == 3 ? ["left", "middle", "right"] : ["left", "right"]
    }

    private var mySide: String { take < sideNames.count ? sideNames[take] : "zone \(take + 1)" }

    /// What the top card says when there is no script (or the prompter is hidden).
    private var defaultCard: CameraCardContent {
        let filmedSides = filmedPeople.sorted().compactMap { $0 < sideNames.count ? sideNames[$0] : nil }
        let sub: String
        if filmedSides.isEmpty {
            sub = "Stay inside your side. Tap record when you're ready."
        } else {
            sub = "Your \(filmedSides.joined(separator: " & ")) take plays silently in its zone. Answer in each gap."
        }
        return CameraCardContent(label: "TAKE \(take + 1) · \(mySide.uppercased()) SIDE",
                                 labelColor: .green,
                                 title: "Stand on the \(mySide).",
                                 sub: sub, countdown: nil)
    }

    private func cardContent(for state: PrompterState) -> CameraCardContent {
        switch state.mode {
        case .ready:
            return CameraCardContent(label: "TAKE \(take + 1) · \(mySide.uppercased()) SIDE", labelColor: .green,
                                     title: state.line, sub: "Your first line. Press record when you're ready.", countdown: nil)
        case .yourLine:
            return CameraCardContent(label: "YOUR TURN", labelColor: .green,
                                     title: state.line, sub: state.next.map { "Next: \($0)" }, countdown: nil)
        case .react:
            return CameraCardContent(label: "OTHER SIDE TALKS", labelColor: RC.blueBright,
                                     title: "React to it", sub: "“\(state.line)”", countdown: nil)
        case .wait:
            return CameraCardContent(label: "PAUSE · THEY TALK HERE", labelColor: .orange,
                                     title: "Leave a gap", sub: "“\(state.line)”", countdown: state.countdown)
        case .done:
            return CameraCardContent(label: "DONE", labelColor: .green,
                                     title: "That's the script", sub: "Tap ✓ to finish the take.", countdown: nil)
        }
    }

    private func timeLabel(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Full-screen live blend. Guides and the red glow sit on the same 9:16 canvas so they line up.
            GeometryReader { g in
                let canvasW = max(g.size.width, g.size.height * 9 / 16)
                let canvasH = canvasW * 16 / 9
                ZStack {
                    LiveBlendView(camera: camera)
                    if split.showGuides {
                        GuideOverlay(split: split, activeZone: take)
                    }
                    if case .crossing(let left) = camera.zoneStatus {
                        let r = split.zoneRange(take)
                        let edge = (left ? r.lowerBound : r.upperBound) * canvasW
                        LinearGradient(colors: [.red.opacity(0), .red.opacity(0.6), .red.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 80)
                            .position(x: edge, y: canvasH / 2)
                            .opacity(pulse ? 1 : 0.35)
                    }
                }
                .frame(width: canvasW, height: canvasH)
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Green / red glow around the screen edge
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .stroke(statusColor, lineWidth: camera.zoneStatus.isCrossing ? 6 : 3)
                .shadow(color: statusColor, radius: 12)
                .opacity(camera.zoneStatus.isCrossing ? (pulse ? 1 : 0.3) : 0.9)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if let n = countdown {
                Text("\(n)")
                    .font(.system(size: 120, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 12)
                    .id(n)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if let err = camera.errorText {
                Text(err).font(.subheadline).foregroundColor(.white).padding()
                    .background(Color.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Controls stay inside the safe area, so nothing hides under the notch or home bar
            VStack(spacing: 0) {
                topCard
                    .padding(.horizontal, 12)
                    .padding(.top, 6)

                HStack {
                    Spacer()
                    toolColumn
                }
                .padding(.trailing, 14)
                .padding(.top, 12)

                Spacer()

                if camera.zoneStatus != .inside {
                    Label(statusText, systemImage: camera.zoneStatus.isCrossing ? "exclamationmark.triangle.fill" : "person.fill.questionmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(camera.zoneStatus.isCrossing ? Color.red.opacity(0.85) : Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(.bottom, 10)
                }

                bottomBar
                    .padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task {
            await loadPlayers()
            await camera.start()
        }
        .onAppear {
            haptics.prepare()
            withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onDisappear {
            countdownTask?.cancel()
            camera.stop()
            players.values.forEach { $0.reset() }
        }
        .onChange(of: split.dividers) { _ in pushConfig() }
        .onChange(of: split.feather) { _ in pushConfig() }
        .onChange(of: split.people) { _ in pushConfig() }
        .onChange(of: split.ghostOpacity) { _ in pushConfig() }
        .onChange(of: camera.zoneStatus) { status in
            if status.isCrossing { haptics.notificationOccurred(.warning) }
        }
        .onChange(of: camera.isRecording) { recording in
            recordStart = recording ? Date() : nil
        }
        .onChange(of: camera.recordedURL) { url in
            guard let url else { return }
            if discardNext {
                // ✕ while recording: throw the take away and stay on the camera
                discardNext = false
                try? FileManager.default.removeItem(at: url)
                camera.recordedURL = nil
                return
            }
            // Watch it back before keeping it
            players.values.forEach { $0.reset() }
            reviewURL = url
            reviewPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            reviewPlayer.play()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === reviewPlayer.currentItem else { return }
            reviewPlayer.seek(to: .zero)
            reviewPlayer.play()
        }
        .overlay {
            if let url = reviewURL {
                TakeReview(player: reviewPlayer, take: take) {
                    // Bad take: delete it and go back to the camera
                    reviewPlayer.pause()
                    reviewPlayer.replaceCurrentItem(with: nil)
                    try? FileManager.default.removeItem(at: url)
                    reviewURL = nil
                    camera.recordedURL = nil
                } onKeep: {
                    reviewPlayer.pause()
                    reviewPlayer.replaceCurrentItem(with: nil)
                    reviewURL = nil
                    camera.recordedURL = nil
                    Task { await keep(url) }
                }
            }
        }
        .sheet(isPresented: $showGuideSettings) {
            GuideSettingsView(split: split)
        }
    }

    // MARK: Camera pieces

    @ViewBuilder private var topCard: some View {
        if split.showPrompter && !split.turns.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let time = recordStart.map { context.date.timeIntervalSince($0) }
                if let state = Prompter.state(turns: split.turns, me: take, time: time,
                                              otherVoice: otherVoice, filmed: filmedPeople) {
                    CameraCard(content: cardContent(for: state), onClose: closeCamera)
                } else {
                    CameraCard(content: defaultCard, onClose: closeCamera)
                }
            }
        } else {
            CameraCard(content: defaultCard, onClose: closeCamera)
        }
    }

    private var toolColumn: some View {
        VStack(spacing: 18) {
            CameraTool(icon: "arrow.triangle.2.circlepath.camera", label: "Flip camera") { camera.flip() }
                .disabled(camera.isRecording || countdown != nil)
            if !split.turns.isEmpty {
                CameraTool(icon: split.showPrompter ? "text.bubble.fill" : "text.bubble",
                           label: split.showPrompter ? "Hide script" : "Show script") { split.showPrompter.toggle() }
            }
            CameraTool(icon: "square.grid.3x3", label: "Guides") { showGuideSettings = true }
                .disabled(camera.isRecording)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let start = recordStart {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 7, height: 7).opacity(pulse ? 1 : 0.3)
                        Text("Take \(take + 1) · \(timeLabel(context.date.timeIntervalSince(start)))").monospacedDigit()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                }
            } else {
                takeSwitcher
            }

            HStack {
                // ✕ discard (only while recording)
                Button {
                    discardNext = true
                    camera.toggleRecording()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Discard this take")
                .opacity(camera.isRecording ? 1 : 0)
                .disabled(!camera.isRecording)

                Spacer()

                Button(action: recordTapped) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.18)).frame(width: 84, height: 84)
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 84, height: 84)
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 7).fill(Color.red).frame(width: 30, height: 30)
                        } else if countdown != nil {
                            Image(systemName: "xmark").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                        } else {
                            Circle().fill(Color.red).frame(width: 66, height: 66)
                        }
                    }
                }
                .accessibilityLabel(camera.isRecording ? "Stop recording" : (countdown != nil ? "Cancel countdown" : "Start recording"))

                Spacer()

                // ✓ finish (only while recording)
                Button { camera.toggleRecording() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Finish take")
                .opacity(camera.isRecording ? 1 : 0)
                .disabled(!camera.isRecording)
            }
            .padding(.horizontal, 36)
        }
    }

    /// 1 / 2 / 3 buttons: jump to any side, including one you already filmed (to redo it).
    private var takeSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(0..<split.people, id: \.self) { zone in
                let selected = zone == take
                Button { switchTo(zone) } label: {
                    HStack(spacing: 4) {
                        Text("\(zone + 1)")
                        if split.takes[zone] != nil {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                        }
                    }
                    .font(.footnote.weight(.bold))
                    .foregroundColor(selected ? .black : .white)
                    .frame(minWidth: 52, minHeight: 32)
                    .background(selected ? Color.white : Color.clear)
                    .clipShape(Capsule())
                }
                .accessibilityLabel("Film take \(zone + 1), \(zone < sideNames.count ? sideNames[zone] : "") side\(split.takes[zone] != nil ? ", filmed" : "")")
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
        .disabled(countdown != nil)
        .opacity(countdown != nil ? 0.4 : 1)
    }

    private func switchTo(_ zone: Int) {
        guard zone != take, !camera.isRecording, countdown == nil else { return }
        tick.impactOccurred()
        take = zone
        Task { await loadPlayers() }
    }

    /// Plays the takes already filmed on the other sides, so you can react to them.
    private func loadPlayers() async {
        players.values.forEach { $0.reset() }
        let current = take
        var loaded: [Int: TakePlayer] = [:]
        for zone in 0..<split.people where zone != current {
            if let clip = split.takes[zone] {
                let p = TakePlayer(url: clip.url)
                await p.prepare()
                loaded[zone] = p
            }
        }
        guard current == take else { return } // switched again while loading
        players = loaded
        otherVoice = nil
        pushConfig()
        if !split.turns.isEmpty, !loaded.isEmpty {
            var all: [ClosedRange<Double>] = []
            for p in loaded.values {
                all += await AutoEditor.voiceRegions(url: p.url, room: .normal)
            }
            if current == take { otherVoice = mergeRanges(all) }
        }
    }

    /// Saves the take, then moves to the next side that still needs filming (or closes when all are done).
    private func keep(_ url: URL) async {
        let kept = take
        await split.setTake(kept, url: url)   // moves it into the project and replaces any old take
        if let next = (0..<split.people).first(where: { split.takes[$0] == nil }) {
            take = next
            await loadPlayers()
        } else {
            closeCamera()
        }
    }

    private func closeCamera() {
        countdownTask?.cancel()
        dismiss()
    }

    private func recordTapped() {
        if camera.isRecording {
            camera.toggleRecording()
        } else if countdown != nil {
            countdownTask?.cancel()
            withAnimation { countdown = nil }
        } else if !Prefs.d.bool(forKey: Prefs.countdown) {
            camera.toggleRecording()
        } else {
            countdownTask = Task { @MainActor in
                for n in [3, 2, 1] {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { countdown = n }
                    tick.impactOccurred()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation { countdown = nil }
                camera.toggleRecording()
            }
        }
    }

    private var filmedPeople: Set<Int> {
        Set(players.keys)
    }

    private func mergeRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound - last.upperBound < 0.9 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    private func pushConfig() {
        camera.update(LiveConfig(
            people: split.people,
            dividers: split.dividers,
            feather: CGFloat(split.feather),
            activeZone: take,
            players: players,
            ghost: CGFloat(split.ghostOpacity)
        ))
    }
}


// MARK: - Camera card (dark instruction card at the top)

struct CameraCardContent: Equatable {
    var label: String
    var labelColor: Color
    var title: String
    var sub: String?
    var countdown: Double?
}

struct CameraCard: View {
    let content: CameraCardContent
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(content.label)
                        .font(.system(size: 12, weight: .heavy))
                        .kerning(0.6)
                        .foregroundColor(content.labelColor)
                    if let c = content.countdown, c > 0.2 {
                        Text(String(format: "%.0fs", c.rounded(.up)))
                            .font(.system(size: 12, weight: .heavy)).monospacedDigit()
                            .foregroundColor(content.labelColor)
                    }
                }
                Text(content.title)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = content.sub {
                    Text(sub)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.14))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Close camera")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.45))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: content)
    }
}

struct CameraTool: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.6), radius: 4)
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Review a take right after recording

struct TakeReview: View {
    let player: AVPlayer
    let take: Int
    let onRetake: () -> Void
    let onKeep: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                CameraCard(content: CameraCardContent(label: "TAKE \(take + 1) · REVIEW", labelColor: .green,
                                                      title: "Keep this take?",
                                                      sub: "Delete it to film it again.", countdown: nil))
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                Spacer()
                HStack(spacing: 12) {
                    Button(action: onRetake) {
                        Label("Delete & retake", systemImage: "trash")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                    }
                    Button(action: onKeep) {
                        Label("Use take", systemImage: "checkmark")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .statusBarHidden(true)
    }
}
