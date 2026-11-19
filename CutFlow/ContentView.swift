import SwiftUI
import PhotosUI
import AVKit
import Combine

// MARK: - Look (one place for every color and shape)

enum RC {
    static let bg = Color(red: 0.027, green: 0.031, blue: 0.051)
    static let card = Color.white.opacity(0.05)
    static let cardHi = Color.white.opacity(0.08)
    static let stroke = Color.white.opacity(0.08)
    static let blue = Color(red: 0.18, green: 0.48, blue: 1.0)
    static let blueBright = Color(red: 0.42, green: 0.66, blue: 1.0)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let success = Color(red: 0.25, green: 0.84, blue: 0.47)
    static let gradient = LinearGradient(colors: [Color(red: 0.22, green: 0.52, blue: 1.0), Color(red: 0.12, green: 0.40, blue: 0.96)],
                                         startPoint: .top, endPoint: .bottom)
    static let radius: CGFloat = 18
}

extension View {
    func rcCard(radius: CGFloat = RC.radius) -> some View {
        self
            .background(RC.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(RC.stroke, lineWidth: 1))
    }
}

/// Plain dark background with one soft blue glow and two thin light lines, kept in the top-right corner.
struct GlowBackground: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                RC.bg
                Circle()
                    .fill(RC.blue.opacity(0.22))
                    .frame(width: 300, height: 300)
                    .blur(radius: 110)
                    .position(x: w * 0.98, y: 20)
                Path { p in
                    p.move(to: CGPoint(x: w + 10, y: 170))
                    p.addCurve(to: CGPoint(x: w * 0.68, y: -10),
                               control1: CGPoint(x: w * 0.86, y: 120),
                               control2: CGPoint(x: w * 0.72, y: 40))
                }
                .stroke(RC.blueBright.opacity(0.45), lineWidth: 1.5)
                .shadow(color: RC.blue.opacity(0.8), radius: 6)
                Path { p in
                    p.move(to: CGPoint(x: w + 10, y: 100))
                    p.addCurve(to: CGPoint(x: w * 0.84, y: -10),
                               control1: CGPoint(x: w * 0.93, y: 66),
                               control2: CGPoint(x: w * 0.86, y: 20))
                }
                .stroke(RC.blue.opacity(0.35), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Root

enum Page: String, CaseIterable {
    case edit = "Edit", clone = "Clone", projects = "Projects", settings = "Settings"

    var icon: String {
        switch self {
        case .edit: return "wand.and.stars"
        case .clone: return "rectangle.split.2x1"
        case .projects: return "square.stack"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @StateObject private var store = ProjectStore()
    @StateObject private var model = EditorModel()
    @StateObject private var split = SplitModel()
    @State private var page: Page = .edit

    var body: some View {
        ZStack {
            GlowBackground()
            // Every tab stays alive underneath, so switching never resets anything
            ForEach(Page.allCases, id: \.self) { p in
                screen(p)
                    .opacity(page == p ? 1 : 0)
                    .allowsHitTesting(page == p)
                    .accessibilityHidden(page != p)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBar(page: $page, badges: [
                .edit: model.isEditing || model.isExporting,
                .clone: split.isRendering
            ])
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.attach(store)
            split.attach(store)
        }
    }

    @ViewBuilder
    private func screen(_ p: Page) -> some View {
        switch p {
        case .edit:
            HomeView(model: model, isActive: page == .edit)
        case .clone:
            SplitView(model: split, isActive: page == .clone)
        case .projects:
            ProjectsView(store: store, editProject: model.projectID, cloneProject: split.projectID) { project in
                open(project)
            } onNew: { kind in
                if kind == .edit { model.newProject(); page = .edit } else { split.newProject(); page = .clone }
            }
        case .settings:
            SettingsView(store: store, split: split)
        }
    }

    private func open(_ project: Project) {
        switch project.kind {
        case .edit:
            model.open(project)
            page = .edit
        case .clone:
            split.open(project)
            page = .clone
        }
    }
}

struct TabBar: View {
    @Binding var page: Page
    var badges: [Page: Bool] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Page.allCases, id: \.self) { p in
                Button {
                    page = p
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: p.icon)
                            .font(.system(size: 19, weight: page == p ? .semibold : .regular))
                            .overlay(alignment: .topTrailing) {
                                if badges[p] == true {
                                    Circle().fill(RC.blue).frame(width: 7, height: 7).offset(x: 6, y: -2)
                                }
                            }
                        Text(p.rawValue).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(page == p ? .white : RC.faint)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(p.rawValue)
                .accessibilityAddTraits(page == p ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(RC.bg.opacity(0.75))
                .overlay(alignment: .top) { Rectangle().fill(RC.stroke).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - Shared building blocks

struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("CF")
                        .font(.system(size: 11, weight: .black))
                        .italic()
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(RC.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    (Text("Cut").foregroundColor(.white) + Text("Flow").foregroundColor(RC.blueBright))
                        .font(.system(size: 14, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(RC.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

struct SectionLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(RC.dim)
            Spacer()
            trailing
        }
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// A rounded card holding rows separated by thin lines.
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .rcCard()
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(RC.stroke).frame(height: 1).padding(.leading, 54)
    }
}

/// One settings row: icon tile, title, and whatever control goes on the right.
struct Row<Trailing: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(RC.blueBright)
                .frame(width: 28, height: 28)
                .background(RC.blue.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(.white)
                if let detail {
                    Text(detail).font(.caption).foregroundColor(RC.dim).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
    }
}

/// Tappable row with a chevron.
struct NavRow: View {
    let icon: String
    let title: String
    var value: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Row(icon: icon, title: title) {
                HStack(spacing: 6) {
                    Text(value).font(.subheadline).foregroundColor(RC.dim).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(RC.faint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PrimaryButton: View {
    let title: String
    let icon: String
    var busy = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                }
                Text(title).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RC.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: RC.blue.opacity(enabled ? 0.35 : 0), radius: 14, y: 4)
        }
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct SecondaryButton: View {
    let title: String
    let icon: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(tint)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RC.cardHi)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct CircleIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(RC.cardHi)
                .clipShape(Circle())
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }
}

func timeString(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
}

// Kept for screens that use the older row helpers (camera, text editor)
struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 86, alignment: .leading)
            content
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .rcCard(radius: 16)
    }
}

struct Segmented<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = selection == option.1
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.1 }
                } label: {
                    Text(option.0)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundColor(selected ? .white : RC.dim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(selected ? RC.blue : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct ToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Row(icon: icon, title: title) {
            Toggle(title, isOn: $isOn).labelsHidden().tint(RC.blue)
        }
        .rcCard(radius: 16)
    }
}

// MARK: - Edit tab (auto edit)

struct HomeView: View {
    @ObservedObject var model: EditorModel
    let isActive: Bool
    @State private var dropItems: [PhotosPickerItem] = []
    @State private var slotItem: PhotosPickerItem?
    @State private var targetSlot: Int?
    @State private var showSlotPicker = false
    @State private var showTextEditor = false
    @State private var confirmNew = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ScreenHeader(title: "Auto edit", subtitle: subtitle) {
                        CircleIconButton(icon: "plus", label: "New edit") {
                            if model.filledCount > 0 { confirmNew = true } else { model.newProject() }
                        }
                    }
                    clipsSection
                    settingsSection
                    if let msg = model.message, !model.showResult {
                        Label(msg, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundColor(RC.dim)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            PrimaryButton(title: model.isEditing ? model.status : "Auto Edit",
                          icon: "sparkles",
                          busy: model.isEditing,
                          enabled: model.filledCount > 0 && !model.isImporting) {
                model.startAutoEdit()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .onChange(of: dropItems) { items in
            guard !items.isEmpty else { return }
            Task {
                await model.importItems(items, into: nil)
                dropItems = []
            }
        }
        .onChange(of: slotItem) { item in
            guard let item, let slot = targetSlot else { return }
            Task {
                await model.importItems([item], into: slot)
                slotItem = nil
                targetSlot = nil
            }
        }
        .photosPicker(isPresented: $showSlotPicker, selection: $slotItem, matching: .videos)
        .sheet(isPresented: $showTextEditor) {
            TextOverlayEditor(texts: $model.texts, background: model.slots.compactMap { $0 }.first?.thumbnail)
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.showResult && isActive },
            set: { model.showResult = $0 }
        )) {
            ResultView(model: model)
        }
        .confirmationDialog("Start a new edit?", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("New edit") { model.newProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This one is saved in Projects.")
        }
    }

    private var subtitle: String {
        guard model.filledCount > 0 else { return "Add clips in order. Clip 1 is your opener." }
        return "\(model.projectName) · saved"
    }

    private func pick(slot: Int) {
        targetSlot = slot
        showSlotPicker = true
    }

    private var clipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Clips") {
                HStack(spacing: 10) {
                    if model.filledCount > 0 {
                        Text("\(model.filledCount) · \(timeString(model.totalSeconds))")
                            .font(.footnote.weight(.medium))
                            .foregroundColor(RC.dim)
                    }
                    PhotosPicker(selection: $dropItems, maxSelectionCount: EditorModel.slotCount, matching: .videos) {
                        HStack(spacing: 4) {
                            if model.isImporting { ProgressView().scaleEffect(0.7).tint(.white) }
                            Text(model.isImporting ? "Adding" : "Add clips")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(RC.blueBright)
                        .frame(minHeight: 32)
                    }
                    .disabled(model.isImporting)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<EditorModel.slotCount, id: \.self) { i in
                        SlotView(
                            number: i + 1,
                            clip: model.slots[i],
                            onPick: { pick(slot: i) },
                            onRemove: { model.clear(slot: i) }
                        )
                    }
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Edit")
            GroupCard {
                Group {
                Row(icon: "clock", title: "Length") {
                    Segmented(options: LengthOption.allCases.map { ($0.label, $0) }, selection: $model.length)
                        .frame(width: 196)
                }
                RowDivider()
                Row(icon: "speedometer", title: "Pace") {
                    Segmented(options: Pace.allCases.map { ($0.rawValue, $0) }, selection: $model.pace)
                        .frame(width: 196)
                }
                RowDivider()
                Row(icon: "waveform.path", title: "Remove silences", detail: "Smooth cuts, no jump cuts") {
                    Toggle("Remove silences", isOn: $model.removeSilences).labelsHidden().tint(RC.blue)
                }
                if model.removeSilences {
                    RowDivider()
                    Row(icon: "ear", title: "Room") {
                        Segmented(options: RoomLevel.allCases.map { ($0.rawValue, $0) }, selection: $model.room)
                            .frame(width: 196)
                    }
                }
                }
                RowDivider()
                Row(icon: "bolt", title: "Hook first", detail: "Best moment plays up front") {
                    Toggle("Hook first", isOn: $model.hookFirst).labelsHidden().tint(RC.blue)
                }
                RowDivider()
                NavRow(icon: "textformat", title: "Text",
                       value: model.texts.isEmpty ? "None" : "\(model.texts.count) added") {
                    showTextEditor = true
                }
            }
        }
    }
}

// MARK: - Clip slot

struct SlotView: View {
    let number: Int
    let clip: Clip?
    let onPick: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Group {
            if let clip {
                Menu {
                    Button(action: onPick) {
                        Label("Replace clip", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    filled(clip)
                }
                .accessibilityLabel("Clip \(number), \(timeString(clip.duration))")
            } else {
                Button(action: onPick) { empty }
                    .accessibilityLabel("Add clip \(number)")
            }
        }
        .frame(width: 78, height: 104)
    }

    private func filled(_ clip: Clip) -> some View {
        ZStack {
            if let img = clip.thumbnail {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                RC.cardHi
                ProgressView().tint(.white)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
        }
        .frame(width: 78, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topLeading) { badge(filled: true) }
        .overlay(alignment: .bottomLeading) {
            Text(timeString(clip.duration))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(7)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(number == 1 ? RC.blue : RC.stroke, lineWidth: number == 1 ? 1.5 : 1)
        )
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(number == 1 ? RC.blueBright : RC.dim)
            Text(number == 1 ? "Opener" : "Clip \(number)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(RC.dim)
        }
        .frame(width: 78, height: 104)
        .background(RC.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topLeading) { badge(filled: false) }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(number == 1 ? RC.blue.opacity(0.8) : Color.white.opacity(0.14),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }

    private func badge(filled: Bool) -> some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(number == 1 ? RC.blue : Color.black.opacity(filled ? 0.6 : 0.3))
            .clipShape(Circle())
            .padding(6)
    }
}

// MARK: - Result

struct ResultView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()

    var body: some View {
        ZStack {
            RC.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    CircleIconButton(icon: "xmark", label: "Close") {
                        player.pause()
                        dismiss()
                    }
                    Spacer()
                    Text("Your cut").font(.headline).foregroundColor(.white)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }

                VideoPlayer(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay {
                        if !model.texts.isEmpty {
                            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                                TextOverlayView(texts: model.texts, time: player.currentTime().seconds)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        if model.isEditing {
                            ZStack {
                                Color.black.opacity(0.55)
                                VStack(spacing: 10) {
                                    ProgressView().tint(.white)
                                    Text(model.status).font(.subheadline).foregroundColor(.white)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                    .frame(maxHeight: .infinity)

                if let r = model.result {
                    HStack(spacing: 6) {
                        Text("\(r.segments.count) parts · \(timeString(r.duration))")
                        let trimmed = model.totalSeconds - r.duration
                        if trimmed >= 1 {
                            Text("·")
                            Text("\(timeString(trimmed)) of silence cut").foregroundColor(RC.blueBright)
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundColor(RC.dim)
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "Re-roll", icon: "shuffle") {
                        model.startAutoEdit(reroll: true)
                    }
                    .disabled(model.isEditing || model.isExporting)
                    .frame(width: 130)

                    PrimaryButton(title: model.savedToPhotos ? "In your Photos" : (model.isExporting ? "Exporting…" : "Export to Photos"),
                                  icon: model.savedToPhotos ? "checkmark" : "square.and.arrow.down",
                                  busy: model.isExporting,
                                  enabled: !model.isEditing && !model.savedToPhotos) {
                        model.startExport()
                    }
                }

                HStack {
                    if let url = model.exportedURL {
                        ShareLink(item: url) {
                            Label("Share to TikTok / Shorts", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(RC.blueBright)
                                .frame(minHeight: 44)
                        }
                    } else if let msg = model.message {
                        Text(msg).font(.footnote).foregroundColor(RC.dim).frame(minHeight: 44)
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .preferredColorScheme(.dark)
        .onAppear { loadPlayer() }
        .onDisappear { player.pause() }
        .onChange(of: model.result?.id) { _ in loadPlayer() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === player.currentItem else { return }
            player.seek(to: .zero)
            player.play()
        }
    }

    private func loadPlayer() {
        guard let r = model.result else { return }
        let item = AVPlayerItem(asset: r.composition)
        item.videoComposition = r.videoComposition
        item.audioMix = r.audioMix
        player.replaceCurrentItem(with: item)
        player.play()
    }
}
