import SwiftUI
import PhotosUI
import Photos
import AVKit
import AVFoundation
import Combine

// MARK: - Model

/// The Clone (split screen) state. Lives for the whole app session, so switching tabs keeps everything.
@MainActor
final class SplitModel: ObservableObject {
    static let guideColors: [Color] = [RC.blue, .white, Color(white: 0.45), Color(red: 0.55, green: 0.7, blue: 1.0)]
    static let minZone: CGFloat = 0.1

    @Published private(set) var people = 2
    @Published var takes: [Clip?] = [nil, nil, nil]
    @Published var dividers: [CGFloat] = [0.5]
    @Published var feather: Double = 40      // px at 1080 wide
    @Published var audio: SplitAudio = .all

    // Camera guides
    @Published var showGuides = true
    @Published var layout: GuideLayout = .split
    @Published var guideColorIndex = 0
    @Published var guideOpacity: Double = 0.9
    /// Earlier take, see-through while filming the next side. Saved as an app setting.
    @Published var ghostOpacity: Double = 0.5 {
        didSet { Prefs.d.set(ghostOpacity, forKey: Prefs.ghost) }
    }

    // Script / teleprompter
    @Published var script: String = Script.sample
    @Published var texts: [TextItem] = []
    @Published var showPrompter = true

    @Published var isRendering = false
    @Published var progress: Double = 0
    @Published var savedToPhotos = false
    @Published var exportedURL: URL?
    @Published var message: String?
    @Published var showResult = false

    @Published private(set) var projectID: UUID?
    private weak var store: ProjectStore?
    private var autosave: AnyCancellable?
    private var isLoading = false

    var guideColor: Color { SplitModel.guideColors[guideColorIndex] }
    var turns: [ScriptTurn] { Script.parse(script, people: people) }
    var activeTakes: [Clip?] { Array(takes.prefix(people)) }
    var isReady: Bool { activeTakes.allSatisfy { $0 != nil } }
    var filmedCount: Int { activeTakes.compactMap { $0 }.count }
    var projectName: String { store?.project(projectID)?.name ?? "New clone" }

    // MARK: Project (backend)

    func attach(_ store: ProjectStore) {
        guard self.store == nil else { return }
        self.store = store
        isLoading = true
        feather = Prefs.d.double(forKey: Prefs.feather)
        ghostOpacity = Prefs.d.double(forKey: Prefs.ghost)
        isLoading = false
        autosave = objectWillChange
            .debounce(for: .seconds(0.8), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
    }

    func newProject() {
        isLoading = true
        projectID = nil
        people = 2
        takes = [nil, nil, nil]
        resetLines()
        feather = Prefs.d.double(forKey: Prefs.feather)
        audio = .all
        script = Script.sample
        texts = []
        clearOutput()
        isLoading = false
    }

    func open(_ project: Project) {
        guard project.kind == .clone, let store else { return }
        isLoading = true
        projectID = project.id
        let data = project.clone ?? CloneData()
        people = min(max(data.people, 2), 3)
        dividers = data.dividers.count == people - 1 ? data.dividers.map { CGFloat($0) }
                                                       : (1..<people).map { CGFloat($0) / CGFloat(people) }
        feather = data.feather
        audio = data.audioTake >= 0 && data.audioTake < people ? .take(data.audioTake) : .all
        script = data.script
        texts = data.texts
        clearOutput()
        takes = (0..<3).map { i -> Clip? in
            guard i < data.takes.count, let saved = data.takes[i] else { return nil }
            let url = store.url(saved.file, in: project.id)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Clip(url: url, duration: saved.duration, thumbnail: nil)
        }
        isLoading = false
        Task {
            for i in takes.indices {
                guard let clip = takes[i], projectID == project.id else { continue }
                let thumb = await store.thumbnail(file: clip.url.lastPathComponent, in: project.id, maxSize: 700)
                if projectID == project.id, takes[i]?.url == clip.url {
                    takes[i] = Clip(url: clip.url, duration: clip.duration, thumbnail: thumb)
                }
            }
        }
    }

    private func ensureProject() -> UUID? {
        if let projectID { return projectID }
        guard let store else { return nil }
        let p = store.create(.clone)
        projectID = p.id
        return p.id
    }

    private func snapshot() -> CloneData {
        var audioTake = -1
        if case .take(let t) = audio { audioTake = t }
        return CloneData(
            people: people,
            takes: takes.map { clip in clip.map { SavedClip(file: $0.url.lastPathComponent, duration: $0.duration) } },
            dividers: dividers.map { Double($0) },
            feather: feather,
            audioTake: audioTake,
            script: script,
            texts: texts
        )
    }

    private func persist() {
        guard !isLoading, let store, let id = projectID, var p = store.project(id) else { return }
        let data = snapshot()
        guard p.clone != data else { return }
        p.clone = data
        store.save(p)
    }

    private func clearOutput() {
        exportedURL = nil
        savedToPhotos = false
        message = nil
        showResult = false
    }

    // MARK: Layout

    func setPeople(_ n: Int) {
        guard n != people else { return }
        people = n
        if case .take(let t) = audio, t >= n { audio = .all }
        resetLines()
    }

    /// Default lines: an even split.
    func resetLines() {
        dividers = (1..<people).map { CGFloat($0) / CGFloat(people) }
    }

    func zoneRange(_ zone: Int) -> ClosedRange<CGFloat> {
        let lo = zone == 0 ? 0 : dividers[min(zone - 1, dividers.count - 1)]
        let hi = zone >= dividers.count ? 1 : dividers[zone]
        return lo...max(lo, hi)
    }

    func move(divider i: Int, to x: CGFloat) {
        let lo = (i == 0 ? 0 : dividers[i - 1]) + SplitModel.minZone
        let hi = (i == dividers.count - 1 ? 1 : dividers[i + 1]) - SplitModel.minZone
        dividers[i] = min(max(x, lo), hi)
    }

    // MARK: Takes

    /// Throws away a bad take so the slot can be filmed again.
    func deleteTake(_ index: Int) {
        guard takes.indices.contains(index), let clip = takes[index] else { return }
        if let store, let id = projectID {
            store.removeFile(clip.url.lastPathComponent, in: id)
        } else {
            try? FileManager.default.removeItem(at: clip.url)
        }
        takes[index] = nil
        exportedURL = nil
        savedToPhotos = false
    }

    /// Keeps a new take (filmed or picked). It's moved into the project, and any old take in that slot is removed.
    func setTake(_ index: Int, url: URL) async {
        var final = url
        if let store, let id = ensureProject(), let name = try? store.adopt(url, into: id) {
            final = store.url(name, in: id)
        }
        let asset = AVURLAsset(url: final)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let thumb = await AutoEditor.thumbnail(for: asset, maxSize: 700)
        if let old = takes[index], old.url != final {
            if let store, let id = projectID { store.removeFile(old.url.lastPathComponent, in: id) }
        }
        takes[index] = Clip(url: final, duration: duration, thumbnail: thumb)
        exportedURL = nil
        savedToPhotos = false
    }

    func importTake(_ index: Int, item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
            message = "Couldn't load that video."
            return
        }
        await setTake(index, url: movie.url)
    }

    // MARK: Export

    /// One tap: blend the takes, keep the video in the project, and save it to Photos.
    /// Owned by the model, so it keeps going if you switch tabs.
    func startExport() {
        guard !isRendering, isReady else { return }
        Task { await exportToPhotos() }
    }

    @discardableResult
    func exportToPhotos() async -> Bool {
        guard await render() else { return false }
        await saveToPhotos()
        showResult = true
        return true
    }

    func render() async -> Bool {
        let urls = activeTakes.compactMap { $0?.url }
        guard urls.count == people else { return false }
        isRendering = true
        message = nil
        defer { isRendering = false }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CutFlow-split-\(UUID().uuidString).mp4")
        do {
            let (comp, video) = try await SplitEditor.build(takes: urls, dividers: dividers, feather: feather, audio: audio, texts: texts)
            progress = 0
            try await SplitEditor.export(composition: comp, videoComposition: video, to: tmp) { [weak self] value in
                self?.progress = value
            }
            var out = tmp
            if let store, let id = ensureProject(),
               let kept = store.addExport(tmp, to: id, duration: comp.duration.seconds) {
                out = kept
            }
            exportedURL = out
            savedToPhotos = false
            return true
        } catch {
            message = "Couldn't make the video: \(error.localizedDescription)"
            return false
        }
    }

    func saveToPhotos() async {
        guard let url = exportedURL else { return }
        savedToPhotos = await PhotoSaver.save(url)
        message = savedToPhotos ? "Saved to your Photos" : "Allow Photos access in Settings to save, or tap Share."
    }
}

struct TakeSlot: Identifiable {
    let id: Int
}

// MARK: - Screen

struct SplitView: View {
    @ObservedObject var model: SplitModel
    let isActive: Bool
    @State private var cameraSlot: TakeSlot?
    @State private var pickerSlot: Int?
    @State private var showPicker = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var showScript = false
    @State private var showText = false
    @State private var deleteSlot: Int?
    @State private var confirmNew = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Clone", subtitle: subtitle) {
                        HStack(spacing: 4) {
                            Segmented(options: [("2", 2), ("3", 3)], selection: Binding(
                                get: { model.people },
                                set: { model.setPeople($0) }
                            ))
                            .frame(width: 84)
                            .accessibilityLabel("Number of people")
                            CircleIconButton(icon: "plus", label: "New clone video") {
                                if model.filmedCount > 0 { confirmNew = true } else { model.newProject() }
                            }
                        }
                    }
                    // Preview on the left, the takes stacked on the right, so the screen fits without scrolling
                    HStack(alignment: .top, spacing: 12) {
                        SplitPreview(model: model)
                            .frame(width: 140, height: 249)
                        takesColumn
                    }
                    GroupCard {
                        NavRow(icon: "text.alignleft", title: "Script",
                               value: model.turns.isEmpty ? "None" : "\(model.turns.count) lines") { showScript = true }
                        RowDivider()
                        NavRow(icon: "textformat", title: "Text",
                               value: model.texts.isEmpty ? "None" : "\(model.texts.count) added") { showText = true }
                        RowDivider()
                        Row(icon: "aqi.medium", title: "Feather") {
                            HStack(spacing: 8) {
                                Slider(value: $model.feather, in: 0...120).tint(RC.blue)
                                    .accessibilityLabel("Feather")
                                Text("\(Int(model.feather))")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(RC.dim)
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .frame(width: 190)
                        }
                        RowDivider()
                        Row(icon: "speaker.wave.2", title: "Audio") {
                            Segmented(options: audioOptions, selection: $model.audio)
                                .frame(width: model.people == 3 ? 206 : 170)
                        }
                    }
                    if let msg = model.message, !model.showResult {
                        Label(msg, systemImage: "info.circle").font(.footnote).foregroundColor(RC.dim)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            PrimaryButton(title: buttonTitle,
                          icon: "square.and.arrow.down",
                          busy: model.isRendering,
                          enabled: model.isReady) {
                model.startExport()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .fullScreenCover(item: $cameraSlot) { slot in
            CameraView(split: model, take: slot.id)
        }
        .photosPicker(isPresented: $showPicker, selection: $pickedItem, matching: .videos)
        .onChange(of: pickedItem) { item in
            guard let item, let slot = pickerSlot else { return }
            Task {
                await model.importTake(slot, item: item)
                pickedItem = nil
                pickerSlot = nil
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.showResult && isActive },
            set: { model.showResult = $0 }
        )) {
            SplitResultView(model: model)
        }
        .sheet(isPresented: $showScript) {
            ScriptEditorView(split: model)
        }
        .sheet(isPresented: $showText) {
            TextOverlayEditor(texts: $model.texts, background: model.takes.compactMap { $0 }.first?.thumbnail)
        }
        .confirmationDialog(
            "Delete take \((deleteSlot ?? 0) + 1)?",
            isPresented: Binding(get: { deleteSlot != nil }, set: { if !$0 { deleteSlot = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete take", role: .destructive) {
                if let slot = deleteSlot { model.deleteTake(slot) }
                deleteSlot = nil
            }
            Button("Cancel", role: .cancel) { deleteSlot = nil }
        } message: {
            Text("The video is removed so you can film this side again.")
        }
        .confirmationDialog("Start a new clone video?", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("New clone video") { model.newProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This one is saved in Projects.")
        }
        .overlay {
            if model.isRendering && isActive {
                JoiningTakesView(progress: model.progress,
                                 background: model.takes.compactMap { $0 }.first?.thumbnail)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.isRendering)
    }

    private var subtitle: String {
        if model.filmedCount == 0 { return "Same person, \(model.people) takes, one video" }
        return "\(model.projectName) · \(model.filmedCount)/\(model.people) filmed"
    }

    private var buttonTitle: String {
        if model.isRendering { return "Exporting… \(Int(model.progress * 100))%" }
        if model.isReady { return "Export to Photos" }
        let left = model.people - model.filmedCount
        return "Film \(left) more take\(left == 1 ? "" : "s")"
    }

    private var audioOptions: [(String, SplitAudio)] {
        [("All", SplitAudio.all)] + (0..<model.people).map { ("Take \($0 + 1)", SplitAudio.take($0)) }
    }

    private var takesColumn: some View {
        VStack(spacing: 8) {
            ForEach(0..<model.people, id: \.self) { i in
                TakeCard(
                    index: i,
                    count: model.people,
                    clip: model.takes[i],
                    onFilm: { cameraSlot = TakeSlot(id: i) },
                    onPick: { pickerSlot = i; showPicker = true },
                    onDelete: { deleteSlot = i }
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Live preview with draggable lines

struct SplitPreview: View {
    @ObservedObject var model: SplitModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let featherFraction = model.feather / 1080

            ZStack {
                RC.card

                // Each take, laid over the last with a soft edge at its line
                ForEach(0..<model.people, id: \.self) { i in
                    TakeLayer(clip: model.takes[i], number: i + 1, zoneCenter: model.zoneRange(i))
                        .frame(width: w, height: h)
                        .mask(zoneMask(for: i, feather: featherFraction))
                }

                TextOverlayView(texts: model.texts)

                // Lines + drag handles
                ForEach(model.dividers.indices, id: \.self) { i in
                    let x = model.dividers[i] * w
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: h))
                    }
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 22, height: 44)
                        .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundColor(.black))
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .frame(width: 44, height: 60)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(coordinateSpace: .named("splitPreview"))
                                .onChanged { value in model.move(divider: i, to: value.location.x / w) }
                        )
                        .position(x: x, y: h - 40)
                        .accessibilityLabel("Line \(i + 1)")
                }

                // Zone numbers
                ForEach(0..<model.people, id: \.self) { zone in
                    let r = model.zoneRange(zone)
                    Text("\(zone + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Circle())
                        .position(x: (r.lowerBound + r.upperBound) / 2 * w, y: 24)
                }
            }
            .coordinateSpace(name: "splitPreview")
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(RC.stroke, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button { model.resetLines() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Reset lines to default")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func zoneMask(for i: Int, feather: Double) -> some View {
        if i == 0 {
            Rectangle()
        } else {
            let d = Double(model.dividers[i - 1])
            let lo = max(0, d - feather / 2)
            let hi = min(1, max(lo + 0.0001, d + feather / 2))
            LinearGradient(
                stops: [.init(color: .clear, location: lo), .init(color: .black, location: hi)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

struct TakeLayer: View {
    let clip: Clip?
    let number: Int
    let zoneCenter: ClosedRange<CGFloat>

    var body: some View {
        GeometryReader { geo in
            if let img = clip?.thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                let shade = [0.10, 0.14, 0.18][(number - 1) % 3]
                ZStack {
                    Color(red: shade * 0.5, green: shade * 0.7, blue: shade + 0.1)
                    VStack(spacing: 6) {
                        Image(systemName: "person.fill").font(.system(size: 34)).foregroundColor(.white.opacity(0.35))
                        Text("Take \(number)").font(.caption.weight(.semibold)).foregroundColor(.white.opacity(0.6))
                    }
                    .position(x: (zoneCenter.lowerBound + zoneCenter.upperBound) / 2 * geo.size.width, y: geo.size.height / 2)
                }
            }
        }
    }
}

struct TakeCard: View {
    let index: Int
    let count: Int
    let clip: Clip?
    let onFilm: () -> Void
    let onPick: () -> Void
    let onDelete: () -> Void

    private var zoneName: String {
        if count == 2 { return index == 0 ? "Left" : "Right" }
        return ["Left", "Middle", "Right"][index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption.weight(.black)).foregroundColor(.white)
                    .frame(width: 20, height: 20).background(clip != nil ? RC.blue : Color.white.opacity(0.12)).clipShape(Circle())
                Text(zoneName).font(.caption.weight(.semibold)).foregroundColor(.white)
                Spacer(minLength: 0)
                if let clip {
                    Text(timeString(clip.duration)).font(.caption2.bold()).foregroundColor(RC.blueBright)
                }
            }
            HStack(spacing: 6) {
                Button(action: onFilm) {
                    Image(systemName: clip == nil ? "video.fill" : "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(clip == nil ? RC.blue : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel(clip == nil ? "Film take \(index + 1)" : "Re-film take \(index + 1)")
                if clip == nil {
                    Button(action: onPick) {
                        Image(systemName: "photo")
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Pick take \(index + 1) from Photos")
                } else {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(Color(red: 1, green: 0.42, blue: 0.4))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Delete take \(index + 1)")
                }
            }
            .font(.subheadline)
            .foregroundColor(.white)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .rcCard(radius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(clip != nil ? RC.blue.opacity(0.7) : .clear, lineWidth: 1))
    }
}

// MARK: - Result

struct SplitResultView: View {
    @ObservedObject var model: SplitModel
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()

    var body: some View {
        ZStack {
            RC.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    CircleIconButton(icon: "xmark", label: "Close") { player.pause(); dismiss() }
                    Spacer()
                    Text("Your clone video").font(.headline).foregroundColor(.white)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                VideoPlayer(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .frame(maxHeight: .infinity)
                HStack(spacing: 10) {
                    if let url = model.exportedURL {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(RC.cardHi)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    PrimaryButton(title: model.savedToPhotos ? "In your Photos" : "Save to Photos",
                                  icon: model.savedToPhotos ? "checkmark" : "square.and.arrow.down",
                                  enabled: !model.savedToPhotos) {
                        Task { await model.saveToPhotos() }
                    }
                }
                Text(model.message ?? " ").font(.footnote).foregroundColor(RC.dim).frame(minHeight: 20)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let url = model.exportedURL {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                player.play()
            }
        }
        .onDisappear { player.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === player.currentItem else { return }
            player.seek(to: .zero)
            player.play()
        }
    }
}


// MARK: - "Joining your takes" while the clones are blended

struct JoiningTakesView: View {
    let progress: Double
    let background: UIImage?
    @State private var spin = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let background {
                Image(uiImage: background)
                    .resizable().scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 18)
                    .opacity(0.55)
            }
            VStack(spacing: 14) {
                Image(systemName: "sparkle")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: spin)
                Text("Joining your takes")
                    .font(.title3.weight(.bold))
                    .foregroundColor(.white)
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(RC.blueBright)
                    .frame(width: 180)
                Text("\(Int(progress * 100))%")
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .onAppear { spin = true }
    }
}
