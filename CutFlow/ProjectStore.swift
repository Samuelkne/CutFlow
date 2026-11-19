import SwiftUI
import AVFoundation
import Combine

// MARK: - What gets saved
//
// The app's on-device backend. Everything lives in the app's Documents folder:
//
//   Documents/Projects/<project id>/project.json   ← settings, clip list, text, script
//   Documents/Projects/<project id>/<uuid>.mov      ← the clips and takes you added
//   Documents/Projects/<project id>/export-*.mp4    ← finished videos
//
// Nothing leaves the phone. Projects survive tab switches, closing the app and restarts.

enum ProjectKind: String, Codable {
    case edit   // Auto edit (6 clips)
    case clone  // Split screen clone video

    var label: String { self == .edit ? "Auto edit" : "Clone video" }
    var icon: String { self == .edit ? "wand.and.stars" : "rectangle.split.2x1" }
}

struct SavedClip: Codable, Equatable {
    var file: String
    var duration: Double
}

struct EditData: Codable, Equatable {
    var slots: [SavedClip?] = Array(repeating: nil, count: 6)
    var length: Double = 30
    var pace: String = Pace.fast.rawValue
    var hookFirst = true
    var removeSilences = true
    var room: String = RoomLevel.normal.rawValue
    var texts: [TextItem] = []
}

struct CloneData: Codable, Equatable {
    var people = 2
    var takes: [SavedClip?] = [nil, nil, nil]
    var dividers: [Double] = [0.5]
    var feather: Double = 40
    var audioTake = -1          // -1 = everyone's audio
    var script = ""
    var texts: [TextItem] = []
}

struct SavedExport: Codable, Identifiable, Equatable {
    var id = UUID()
    var file: String
    var date = Date()
    var duration: Double
}

struct Project: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ProjectKind
    var name: String
    var created = Date()
    var updated = Date()
    var edit: EditData?
    var clone: CloneData?
    var exports: [SavedExport] = []

    var clipCount: Int {
        switch kind {
        case .edit: return edit?.slots.compactMap { $0 }.count ?? 0
        case .clone: return clone?.takes.prefix(clone?.people ?? 2).compactMap { $0 }.count ?? 0
        }
    }

    var firstFile: String? {
        switch kind {
        case .edit: return edit?.slots.compactMap { $0 }.first?.file
        case .clone: return clone?.takes.compactMap { $0 }.first?.file
        }
    }
}

// MARK: - Store

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []   // newest first
    @Published private(set) var storageBytes: Int64 = 0

    let root: URL
    private var thumbs: [String: UIImage] = [:]
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        loadAll()
    }

    // MARK: Paths

    func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(_ file: String, in id: UUID) -> URL {
        folder(id).appendingPathComponent(file)
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    // MARK: Load / save

    func loadAll() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Project] = []
        for dir in dirs {
            let json = dir.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: json), let p = try? decoder.decode(Project.self, from: data) {
                loaded.append(p)
            }
        }
        projects = loaded.sorted { $0.updated > $1.updated }
        refreshStorage()
    }

    func save(_ project: Project, touch: Bool = true) {
        var p = project
        if touch { p.updated = Date() }
        let dir = folder(p.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(p) {
            try? data.write(to: dir.appendingPathComponent("project.json"), options: .atomic)
        }
        if let i = projects.firstIndex(where: { $0.id == p.id }) {
            projects[i] = p
        } else {
            projects.append(p)
        }
        projects.sort { $0.updated > $1.updated }
    }

    func create(_ kind: ProjectKind) -> Project {
        let count = projects.filter { $0.kind == kind }.count + 1
        let p = Project(kind: kind,
                        name: kind == .edit ? "Edit \(count)" : "Clone \(count)",
                        edit: kind == .edit ? EditData() : nil,
                        clone: kind == .clone ? CloneData() : nil)
        save(p)
        return p
    }

    func rename(_ id: UUID, to name: String) {
        guard var p = project(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        p.name = trimmed
        save(p, touch: false)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
        projects.removeAll { $0.id == id }
        refreshStorage()
    }

    // MARK: Files

    /// Brings a video into the project folder. Temporary files are moved, anything else is copied.
    func adopt(_ source: URL, into id: UUID) throws -> String {
        let dir = folder(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if source.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
            return source.lastPathComponent // already ours
        }
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        let dest = dir.appendingPathComponent(name)
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if source.standardizedFileURL.path.hasPrefix(tmp) {
            do { try FileManager.default.moveItem(at: source, to: dest) }
            catch { try FileManager.default.copyItem(at: source, to: dest) }
        } else {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        refreshStorage()
        return name
    }

    func removeFile(_ file: String, in id: UUID) {
        try? FileManager.default.removeItem(at: url(file, in: id))
        thumbs[url(file, in: id).path] = nil
        refreshStorage()
    }

    func addExport(_ source: URL, to id: UUID, duration: Double) -> URL? {
        guard var p = project(id) else { return nil }
        let name = "export-\(Int(Date().timeIntervalSince1970)).mp4"
        let dest = url(name, in: id)
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: source, to: dest)
        } catch {
            return nil
        }
        p.exports.insert(SavedExport(file: name, duration: duration), at: 0)
        save(p)
        refreshStorage()
        return dest
    }

    func deleteExport(_ export: SavedExport, from id: UUID) {
        guard var p = project(id) else { return }
        removeFile(export.file, in: id)
        p.exports.removeAll { $0.id == export.id }
        save(p, touch: false)
    }

    func deleteAllExports() {
        for var p in projects where !p.exports.isEmpty {
            for e in p.exports { removeFile(e.file, in: p.id) }
            p.exports = []
            save(p, touch: false)
        }
    }

    /// Every export, newest first, with the project it belongs to.
    var allExports: [(project: Project, export: SavedExport)] {
        projects.flatMap { p in p.exports.map { (project: p, export: $0) } }.sorted { $0.export.date > $1.export.date }
    }

    // MARK: Thumbnails

    func thumbnail(file: String, in id: UUID, maxSize: CGFloat = 400) async -> UIImage? {
        let u = url(file, in: id)
        if let cached = thumbs[u.path] { return cached }
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let img = await AutoEditor.thumbnail(for: AVURLAsset(url: u), maxSize: maxSize)
        thumbs[u.path] = img
        return img
    }

    // MARK: Storage

    func refreshStorage() {
        let fm = FileManager.default
        var total: Int64 = 0
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        storageBytes = total
    }
}

// MARK: - App-wide settings (saved on the phone)

enum Prefs {
    static let smoothCuts = "smoothCuts"
    static let cutReaches = "cutReaches"
    static let length = "defaultLength"
    static let pace = "defaultPace"
    static let room = "defaultRoom"
    static let hookFirst = "defaultHookFirst"
    static let removeSilences = "defaultRemoveSilences"
    static let feather = "defaultFeather"
    static let ghost = "ghostOpacity"
    static let countdown = "cameraCountdown"

    static func register() {
        UserDefaults.standard.register(defaults: [
            smoothCuts: true,
            cutReaches: true,
            length: 30.0,
            pace: Pace.fast.rawValue,
            room: RoomLevel.normal.rawValue,
            hookFirst: true,
            removeSilences: true,
            feather: 40.0,
            ghost: 0.5,
            countdown: true
        ])
    }

    static var d: UserDefaults { .standard }
}
