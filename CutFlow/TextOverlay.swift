import SwiftUI
import UIKit

// MARK: - Model

enum TextLook: String, CaseIterable, Identifiable, Codable {
    case box = "Box"          // black text on a white box (classic TikTok)
    case outline = "Outline"  // white text, black outline
    case blue = "Blue"        // white text on a blue pill

    var id: String { rawValue }
}

enum TextSize: String, CaseIterable, Identifiable, Codable {
    case small = "S", medium = "M", large = "L"

    var id: String { rawValue }
    /// Font size at 1080 px wide
    var points: CGFloat {
        switch self {
        case .small: return 46
        case .medium: return 62
        case .large: return 84
        }
    }
}

enum TextTiming: String, CaseIterable, Identifiable, Codable {
    case whole = "Whole video"
    case hook = "First 3s"

    var id: String { rawValue }
    var end: Double? { self == .hook ? 3 : nil }
}

struct TextItem: Identifiable, Equatable, Codable {
    var id = UUID()
    var text: String = "Tap to edit"
    var y: Double = 0.18          // 0 = top, 1 = bottom
    var look: TextLook = .box
    var size: TextSize = .medium
    var timing: TextTiming = .whole

    func isVisible(at time: Double?) -> Bool {
        guard let end = timing.end, let t = time else { return true }
        return t < end
    }
}

// MARK: - Drawing (the same image is used for the preview and the export)

enum TextRenderer {
    static let canvas = CGSize(width: 1080, height: 1920)

    static func image(for item: TextItem) -> UIImage? {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let fontSize = item.size.points
        let font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        switch item.look {
        case .box:
            attrs[.foregroundColor] = UIColor.black
        case .blue:
            attrs[.foregroundColor] = UIColor.white
        case .outline:
            attrs[.foregroundColor] = UIColor.white
            attrs[.strokeColor] = UIColor.black
            attrs[.strokeWidth] = -7
        }
        let string = NSAttributedString(string: text, attributes: attrs)
        let maxWidth = canvas.width * 0.84
        let bounds = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let padX = item.look == .outline ? fontSize * 0.12 : fontSize * 0.45
        let padY = item.look == .outline ? fontSize * 0.12 : fontSize * 0.24
        let size = CGSize(width: bounds.width + padX * 2, height: bounds.height + padY * 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            if item.look != .outline {
                let fill = item.look == .box ? UIColor.white : UIColor(red: 0, green: 0.45, blue: 1, alpha: 1)
                fill.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: fontSize * 0.32).fill()
            }
            string.draw(with: CGRect(x: padX, y: padY, width: bounds.width, height: bounds.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }

    /// Where the text sits on the 1080x1920 canvas (top-left origin).
    static func frame(for size: CGSize, y: Double) -> CGRect {
        let centerY = CGFloat(y) * canvas.height
        let top = min(max(centerY - size.height / 2, 60), canvas.height - size.height - 60)
        return CGRect(x: (canvas.width - size.width) / 2, y: top, width: size.width, height: size.height)
    }
}

// MARK: - Shows the texts over a 9:16 frame

struct TextOverlayView: View {
    let texts: [TextItem]
    var time: Double? = nil
    var highlighted: UUID? = nil

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / TextRenderer.canvas.width
            ForEach(texts) { item in
                if item.isVisible(at: time), let img = TextRenderer.image(for: item) {
                    let f = TextRenderer.frame(for: img.size, y: item.y)
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: f.width * scale, height: f.height * scale)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(RC.blueBright, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .padding(-4)
                                .opacity(item.id == highlighted ? 1 : 0)
                        )
                        .position(x: f.midX * scale, y: f.midY * scale)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Editor

struct TextOverlayEditor: View {
    @Binding var texts: [TextItem]
    var background: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?

    private var selectedIndex: Int? {
        guard let selected else { return nil }
        return texts.firstIndex { $0.id == selected }
    }

    var body: some View {
        ZStack {
            RC.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Button("Done") { dismiss() }
                        .font(.headline).foregroundColor(RC.blueBright).frame(minHeight: 44)
                    Spacer()
                    Text("Text").font(.title3.bold()).foregroundColor(.white)
                    Spacer()
                    Button {
                        let item = TextItem(y: texts.isEmpty ? 0.18 : min(0.85, (texts.last?.y ?? 0.18) + 0.12))
                        texts.append(item)
                        selected = item.id
                    } label: {
                        Label("Add", systemImage: "plus").font(.headline).foregroundColor(RC.blueBright)
                    }
                    .frame(minHeight: 44)
                }

                // Preview: drag up/down to move the selected text
                GeometryReader { geo in
                    ZStack {
                        if let bg = background {
                            Image(uiImage: bg).resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height).clipped()
                                .overlay(Color.black.opacity(0.15))
                        } else {
                            Color(red: 0.1, green: 0.13, blue: 0.2)
                        }
                        TextOverlayView(texts: texts, highlighted: selected)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            guard let i = selectedIndex else { return }
                            texts[i].y = min(max(Double(value.location.y / geo.size.height), 0.05), 0.95)
                        }
                    )
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(RC.stroke, lineWidth: 1))

                // Pick which text to edit
                if !texts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(texts) { item in
                                Button { selected = item.id } label: {
                                    Text(item.text.isEmpty ? "Empty" : item.text)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .frame(maxWidth: 160, minHeight: 36)
                                        .background(item.id == selected ? AnyShapeStyle(RC.gradient) : AnyShapeStyle(RC.card))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }

                if let i = selectedIndex {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("Your text", text: $texts[i].text, axis: .vertical)
                                    .font(.body)
                                    .foregroundColor(.white)
                                    .lineLimit(1...3)
                                    .padding(12)
                                    .rcCard(radius: 14)
                                Button {
                                    texts.remove(at: i)
                                    selected = texts.last?.id
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(Color(red: 1, green: 0.42, blue: 0.4))
                                        .frame(width: 48, height: 48)
                                        .rcCard(radius: 14)
                                }
                                .accessibilityLabel("Delete text")
                            }
                            SettingRow(icon: "textformat", title: "Style") {
                                Segmented(options: TextLook.allCases.map { ($0.rawValue, $0) }, selection: $texts[i].look)
                            }
                            SettingRow(icon: "textformat.size", title: "Size") {
                                Segmented(options: TextSize.allCases.map { ($0.rawValue, $0) }, selection: $texts[i].size)
                            }
                            SettingRow(icon: "clock", title: "Show") {
                                Segmented(options: TextTiming.allCases.map { ($0.rawValue, $0) }, selection: $texts[i].timing)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "textformat").font(.title).foregroundColor(RC.blueBright)
                        Text(texts.isEmpty ? "Tap Add to put text on your video." : "Pick a text above to edit it.")
                            .font(.subheadline).foregroundColor(RC.dim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
        .onAppear { if selected == nil { selected = texts.first?.id } }
    }
}
