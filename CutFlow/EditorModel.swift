import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import Combine

enum LengthOption: Double, CaseIterable, Identifiable {
    case s15 = 15
    case s30 = 30
    case s60 = 60
    case full = 9999

    var id: Double { rawValue }
    var label: String { self == .full ? "Full" : "\(Int(rawValue))s" }
}

/// The Auto Edit screen's state. It lives for the whole app session (not per tab),
/// so switching tabs never loses clips, settings or an edit in progress.
@MainActor
final class EditorModel: ObservableObject {
    static let slotCount = 6

    @Published var slots: [Clip?] = Array(repeating: nil, count: EditorModel.slotCount)
    @Published var length: LengthOption = .s30
    @Published var pace: Pace = .fast
    @Published var hookFirst = true
    @Published var removeSilences = true
    @Published var room: RoomLevel = .normal
    @Published var texts: [TextItem] = []

    @Published var isImporting = false
    @Published var isEditing = false
    @Published var isExporting = false
    @Published var status = ""
    @Published var message: String?
    @Published var result: EditResult?
    @Published var hookSlot: Int?
    @Published var exportedURL: URL?
    @Published var savedToPhotos = false
    @Published var showResult = false

    @Published private(set) var projectID: UUID?
    private weak var store: ProjectStore?
    private var autosave: AnyCancellable?
    private var isLoading = false

    var filledCount: Int { slots.compactMap { $0 }.count }
    var totalSeconds: Double { slots.compactMap { $0 }.reduce(0) { $0 + $1.duration } }
    var projectName: String { store?.project(projectID)?.name ?? "New edit" }

    // MARK: Project (backend)

    func attach(_ store: ProjectStore) {
        guard self.store == nil else { return }
        self.store = store
        applyDefaults()
        // Save a moment after anything changes
        autosave = objectWillChange
            .debounce(for: .seconds(0.8), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
    }

    private func applyDefaults() {
        let d = Prefs.d
        length = LengthOption(rawValue: d.double(forKey: Prefs.length)) ?? .s30
        pace = Pace(rawValue: d.string(forKey: Prefs.pace) ?? "") ?? .fast
        room = RoomLevel(rawValue: d.string(forKey: Prefs.room) ?? "") ?? .normal
        hookFirst = d.bool(forKey: Prefs.hookFirst)
        removeSilences = d.bool(forKey: Prefs.removeSilences)
    }

    /// Starts a blank edit. The project is created on disk when the first clip is added.
    func newProject() {
        isLoading = true
        projectID = nil
        slots = Array(repeating: nil, count: EditorModel.slotCount)
        texts = []
        clearOutput()
        applyDefaults()
        isLoading = false
    }

    func open(_ project: Project) {
        guard project.kind == .edit, let store else { return }
        isLoading = true
        projectID = project.id
        let data = project.edit ?? EditData()
        length = LengthOption(rawValue: data.length) ?? .s30
        pace = Pace(rawValue: data.pace) ?? .fast
        room = RoomLevel(rawValue: data.room) ?? .normal
        hookFirst = data.hookFirst
        removeSilences = data.removeSilences
        texts = data.texts
        clearOutput()
        slots = (0..<EditorModel.slotCount).map { i -> Clip? in
            guard i < data.slots.count, let saved = data.slots[i] else { return nil }
            let url = store.url(saved.file, in: project.id)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Clip(url: url, duration: saved.duration, thumbnail: nil)
        }
        isLoading = false
        // Thumbnails load in the background
        Task {
            for i in slots.indices {
                guard let clip = slots[i], clip.thumbnail == nil, projectID == project.id else { continue }
                let thumb = await store.thumbnail(file: clip.url.lastPathComponent, in: project.id, maxSize: 300)
                if projectID == project.id, slots[i]?.url == clip.url {
                    slots[i] = Clip(url: clip.url, duration: clip.duration, thumbnail: thumb)
                }
            }
        }
    }

    private func ensureProject() -> UUID? {
        if let projectID { return projectID }
        guard let store else { return nil }
        let p = store.create(.edit)
        projectID = p.id
        return p.id
    }

    private func snapshot() -> EditData {
        EditData(
            slots: slots.map { clip in clip.map { SavedClip(file: $0.url.lastPathComponent, duration: $0.duration) } },
            length: length.rawValue,
            pace: pace.rawValue,
            hookFirst: hookFirst,
            removeSilences: removeSilences,
            room: room.rawValue,
            texts: texts
        )
    }

    private func persist() {
        guard !isLoading, let store, let id = projectID, var p = store.project(id) else { return }
        let data = snapshot()
        guard p.edit != data else { return }
        p.edit = data
        store.save(p)
    }

    private func clearOutput() {
        result = nil
        exportedURL = nil
        savedToPhotos = false
        hookSlot = nil
        message = nil
        showResult = false
    }

    // MARK: Clips

    /// Puts picked videos into a specific slot, or fills empty slots in order.
    func importItems(_ items: [PhotosPickerItem], into slot: Int?) async {
        isImporting = true
        defer { isImporting = false }
        message = nil
        let targets: [Int]
        if let slot {
            targets = [slot]
        } else {
            targets = slots.indices.filter { slots[$0] == nil }
        }
        if items.count > targets.count {
            let extra = items.count - targets.count
            message = "There are only 6 clip slots, so \(extra) clip\(extra == 1 ? "" : "s") weren't added."
        }
        var failed = 0
        for (n, item) in items.prefix(targets.count).enumerated() {
            if let clip = await loadClip(item) {
                let target = targets[n]
                if let old = slots[target], let store, let id = projectID {
                    store.removeFile(old.url.lastPathComponent, in: id)
                }
                slots[target] = clip
                result = nil
            } else {
                failed += 1
            }
        }
        if failed > 0 {
            message = "\(failed) video\(failed == 1 ? "" : "s") couldn't be loaded."
        }
    }

    private func loadClip(_ item: PhotosPickerItem) async -> Clip? {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return nil }
        var url = movie.url
        if let store, let id = ensureProject(), let name = try? store.adopt(movie.url, into: id) {
            url = store.url(name, in: id)
        }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration > 0.2 else { return nil }
        let thumb = await AutoEditor.thumbnail(for: asset)
        return Clip(url: url, duration: duration, thumbnail: thumb)
    }

    func clear(slot: Int) {
        guard let clip = slots[slot] else { return }
        if let store, let id = projectID {
            store.removeFile(clip.url.lastPathComponent, in: id)
        }
        slots[slot] = nil
        result = nil
    }

    // MARK: Edit

    /// Runs on its own task owned by this model, so it keeps going if you switch tabs.
    func startAutoEdit(reroll: Bool = false) {
        guard !isEditing else { return }
        Task { await autoEdit(reroll: reroll) }
    }

    func autoEdit(reroll: Bool = false) async {
        let infos: [ClipInfo] = slots.enumerated().compactMap { index, clip in
            guard let clip else { return nil }
            return ClipInfo(url: clip.url, duration: clip.duration, slot: index + 1)
        }
        guard !infos.isEmpty else { return }

        isEditing = true
        exportedURL = nil
        savedToPhotos = false
        message = nil
        status = removeSilences ? "Cutting out silences…" : "Reading clips…"

        let settings = EditSettings(
            target: length.rawValue,
            pace: pace,
            hookFirst: hookFirst,
            smoothCuts: Prefs.d.bool(forKey: Prefs.smoothCuts),
            removeSilences: removeSilences,
            room: room,
            reroll: reroll
        )

        do {
            let segments = await Task.detached(priority: .userInitiated) {
                await AutoEditor.pickSegments(clips: infos, settings: settings)
            }.value
            guard !segments.isEmpty else {
                message = "Couldn't find anything to keep in these clips."
                isEditing = false
                return
            }
            status = "Building your cut…"
            let built = try await AutoEditor.build(clips: infos, segments: segments, settings: settings)
            if hookFirst, infos.count > 1, let first = built.segments.first, first.clipIndex > 0 {
                hookSlot = infos[first.clipIndex].slot
            } else {
                hookSlot = nil
            }
            result = built
            showResult = true
        } catch {
            message = "Couldn't build the edit: \(error.localizedDescription)"
        }
        isEditing = false
    }

    // MARK: Export

    func startExport() {
        guard !isExporting else { return }
        Task { await exportAndSave() }
    }

    func exportAndSave() async {
        guard let result else { return }
        isExporting = true
        defer { isExporting = false }
        message = nil
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CutFlow-\(UUID().uuidString).mp4")
        do {
            try await AutoEditor.export(result, to: tmp, texts: texts)
            var out = tmp
            if let store, let id = ensureProject(), let kept = store.addExport(tmp, to: id, duration: result.duration) {
                out = kept
            }
            exportedURL = out
            savedToPhotos = await PhotoSaver.save(out)
            message = savedToPhotos ? "Saved to your Photos" : "Exported. Allow Photos access in Settings to save, or tap Share."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}

enum PhotoSaver {
    /// Saves a video to the camera roll. Returns false if Photos access was denied or it failed.
    static func save(_ url: URL) async -> Bool {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return true
        } catch {
            return false
        }
    }
}
