import SwiftUI

// MARK: - Settings tab

struct SettingsView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var split: SplitModel

    @AppStorage(Prefs.smoothCuts) private var smoothCuts = true
    @AppStorage(Prefs.cutReaches) private var cutReaches = true
    @AppStorage(Prefs.length) private var length = 30.0
    @AppStorage(Prefs.pace) private var pace = Pace.fast.rawValue
    @AppStorage(Prefs.room) private var room = RoomLevel.normal.rawValue
    @AppStorage(Prefs.hookFirst) private var hookFirst = true
    @AppStorage(Prefs.removeSilences) private var removeSilences = true
    @AppStorage(Prefs.feather) private var feather = 40.0
    @AppStorage(Prefs.countdown) private var countdown = true

    @State private var confirmClear = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader(title: "Settings", subtitle: "Saved on this iPhone") { EmptyView() }

                section("Editing") {
                    Group {
                    Row(icon: "wand.and.rays", title: "Smooth cuts", detail: "Quick blend at every cut, no jump cuts") {
                        Toggle("Smooth cuts", isOn: $smoothCuts).labelsHidden().tint(RC.blue)
                    }
                    RowDivider()
                    Row(icon: "hand.raised", title: "Cut camera reaches", detail: "Trims where you reach to start or stop") {
                        Toggle("Cut camera reaches", isOn: $cutReaches).labelsHidden().tint(RC.blue)
                    }
                    RowDivider()
                    Row(icon: "waveform.path", title: "Remove silences", detail: "Default for new edits") {
                        Toggle("Remove silences", isOn: $removeSilences).labelsHidden().tint(RC.blue)
                    }
                    RowDivider()
                    Row(icon: "bolt", title: "Hook first", detail: "Default for new edits") {
                        Toggle("Hook first", isOn: $hookFirst).labelsHidden().tint(RC.blue)
                    }
                    }
                    RowDivider()
                    Group {
                    Row(icon: "clock", title: "Length") {
                        Segmented(options: LengthOption.allCases.map { ($0.label, $0.rawValue) }, selection: $length)
                            .frame(width: 196)
                    }
                    RowDivider()
                    Row(icon: "speedometer", title: "Pace") {
                        Segmented(options: Pace.allCases.map { ($0.rawValue, $0.rawValue) }, selection: $pace)
                            .frame(width: 196)
                    }
                    RowDivider()
                    Row(icon: "ear", title: "Room") {
                        Segmented(options: RoomLevel.allCases.map { ($0.rawValue, $0.rawValue) }, selection: $room)
                            .frame(width: 196)
                    }
                    }
                }

                section("Clone camera") {
                    Row(icon: "circle.dotted", title: "Earlier take", detail: "See-through and silent while filming") {
                        sliderValue("\(Int(split.ghostOpacity * 100))%")
                    }
                    Slider(value: $split.ghostOpacity, in: 0.15...1)
                        .tint(RC.blue)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .accessibilityLabel("Earlier take opacity")
                    RowDivider()
                    Row(icon: "aqi.medium", title: "Feather", detail: "Default edge softness for new clones") {
                        sliderValue("\(Int(feather))")
                    }
                    Slider(value: $feather, in: 0...120)
                        .tint(RC.blue)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .accessibilityLabel("Default feather")
                    RowDivider()
                    Row(icon: "timer", title: "3·2·1 countdown", detail: "Before each take") {
                        Toggle("Countdown", isOn: $countdown).labelsHidden().tint(RC.blue)
                    }
                }

                section("Storage") {
                    Row(icon: "internaldrive", title: "Used by CutFlow") {
                        Text(ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file))
                            .font(.subheadline).foregroundColor(RC.dim)
                    }
                    RowDivider()
                    Button { confirmClear = true } label: {
                        Row(icon: "trash", title: "Delete all exports", detail: "Projects and clips stay") {
                            EmptyView()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.allExports.isEmpty)
                    .opacity(store.allExports.isEmpty ? 0.45 : 1)
                }

                section("About") {
                    Row(icon: "info.circle", title: "Version") {
                        Text(appVersion).font(.subheadline).foregroundColor(RC.dim)
                    }
                    RowDivider()
                    Row(icon: "arrow.clockwise", title: "Keeping it installed",
                        detail: "Re-install with Sideloadly every 7 days. Projects are kept.") {
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .onAppear { store.refreshStorage() }
        .confirmationDialog("Delete all exports?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete exports", role: .destructive) { store.deleteAllExports() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Videos already saved to Photos stay there. You can export again any time.")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            GroupCard { content() }
        }
    }

    private func sliderValue(_ text: String) -> some View {
        Text(text).font(.subheadline.monospacedDigit()).foregroundColor(RC.dim)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
