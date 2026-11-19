import SwiftUI
import AVKit

// MARK: - Projects tab

struct ProjectsView: View {
    @ObservedObject var store: ProjectStore
    let editProject: UUID?
    let cloneProject: UUID?
    let onOpen: (Project) -> Void
    let onNew: (ProjectKind) -> Void

    @State private var renaming: Project?
    @State private var newName = ""
    @State private var deleting: Project?
    @State private var playing: ExportRef?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader(title: "Projects", subtitle: summary) {
                    Menu {
                        Button { onNew(.edit) } label: { Label("New auto edit", systemImage: ProjectKind.edit.icon) }
                        Button { onNew(.clone) } label: { Label("New clone video", systemImage: ProjectKind.clone.icon) }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(RC.cardHi)
                            .clipShape(Circle())
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("New project")
                }

                if !store.allExports.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Exports")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(store.allExports.prefix(20).map { ExportRef(project: $0.project, export: $0.export) }) { ref in
                                    ExportThumb(store: store, project: ref.project, export: ref.export) {
                                        playing = ref
                                    }
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("All projects")
                    if store.projects.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 8) {
                            ForEach(store.projects) { project in
                                ProjectRow(store: store, project: project,
                                           isOpen: project.id == editProject || project.id == cloneProject) {
                                    onOpen(project)
                                }
                                .contextMenu {
                                    Button { onOpen(project) } label: { Label("Open", systemImage: "arrow.up.right") }
                                    Button {
                                        newName = project.name
                                        renaming = project
                                    } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { deleting = project } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let p = renaming { store.rename(p.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "project")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete project", role: .destructive) {
                if let p = deleting {
                    if p.id == editProject || p.id == cloneProject {
                        // Don't delete the one that's open on another tab out from under it
                        onNew(p.kind)
                    }
                    store.delete(p.id)
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its clips and exports are removed from CutFlow. Anything already saved to Photos stays there.")
        }
        .sheet(item: $playing) { ref in
            ExportPlayer(store: store, ref: ref)
        }
    }

    private var summary: String {
        let n = store.projects.count
        guard n > 0 else { return "Everything you make is saved here" }
        let exports = store.allExports.count
        return "\(n) project\(n == 1 ? "" : "s") · \(exports) export\(exports == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(RC.blueBright)
                .frame(width: 60, height: 60)
                .background(RC.blue.opacity(0.14))
                .clipShape(Circle())
            Text("No projects yet").font(.headline).foregroundColor(.white)
            Text("Add clips on the Edit tab or film on the Clone tab. Your work saves here automatically.")
                .font(.subheadline)
                .foregroundColor(RC.dim)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                SecondaryButton(title: "Auto edit", icon: ProjectKind.edit.icon) { onNew(.edit) }
                SecondaryButton(title: "Clone", icon: ProjectKind.clone.icon) { onNew(.clone) }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .rcCard()
    }
}

struct ExportRef: Identifiable {
    let project: Project
    let export: SavedExport
    var id: UUID { export.id }
}

struct ProjectRow: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    let isOpen: Bool
    let action: () -> Void
    @State private var thumb: UIImage?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RC.cardHi
                    if let thumb {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Image(systemName: project.kind.icon).foregroundColor(RC.dim)
                    }
                }
                .frame(width: 48, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(project.name).font(.system(size: 16, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                        if isOpen {
                            Text("OPEN")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(RC.blueBright)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RC.blue.opacity(0.16))
                                .clipShape(Capsule())
                        }
                    }
                    Text(detail).font(.footnote).foregroundColor(RC.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(RC.faint)
            }
            .padding(10)
            .rcCard(radius: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: project.firstFile) {
            guard let file = project.firstFile else { thumb = nil; return }
            thumb = await store.thumbnail(file: file, in: project.id, maxSize: 200)
        }
    }

    private var detail: String {
        let clips = project.clipCount
        let unit = project.kind == .edit ? "clip" : "take"
        var parts = [project.kind.label, "\(clips) \(unit)\(clips == 1 ? "" : "s")"]
        if !project.exports.isEmpty { parts.append("\(project.exports.count) export\(project.exports.count == 1 ? "" : "s")") }
        parts.append(project.updated.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

struct ExportThumb: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    let export: SavedExport
    let action: () -> Void
    @State private var thumb: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RC.cardHi
                if let thumb { Image(uiImage: thumb).resizable().scaledToFill() }
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeString(export.duration)).font(.system(size: 11, weight: .bold))
                    Text(project.name).font(.system(size: 10)).opacity(0.8).lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(7)
            }
            .frame(width: 84, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(Image(systemName: "play.fill").font(.system(size: 14)).foregroundColor(.white.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play export from \(project.name)")
        .task { thumb = await store.thumbnail(file: export.file, in: project.id, maxSize: 240) }
    }
}

struct ExportPlayer: View {
    @ObservedObject var store: ProjectStore
    let ref: ExportRef
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var saved = false
    @State private var confirmDelete = false

    private var url: URL { store.url(ref.export.file, in: ref.project.id) }

    var body: some View {
        ZStack {
            RC.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    CircleIconButton(icon: "xmark", label: "Close") { dismiss() }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(ref.project.name).font(.headline).foregroundColor(.white)
                        Text(ref.export.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(RC.dim)
                    }
                    Spacer()
                    CircleIconButton(icon: "trash", label: "Delete export") { confirmDelete = true }
                }
                VideoPlayer(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .frame(maxHeight: .infinity)
                HStack(spacing: 10) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(RC.cardHi)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    PrimaryButton(title: saved ? "Saved" : "Save to Photos",
                                  icon: saved ? "checkmark" : "square.and.arrow.down",
                                  enabled: !saved) {
                        Task { saved = await PhotoSaver.save(url) }
                    }
                }
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        }
        .onDisappear { player.pause() }
        .confirmationDialog("Delete this export?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player.pause()
                store.deleteExport(ref.export, from: ref.project.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A copy already saved to Photos stays there.")
        }
    }
}
