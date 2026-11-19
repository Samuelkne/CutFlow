import SwiftUI
import UIKit
import ImageIO

/// The CutFlow launch animation (intro.gif), played once before the home screen.
enum IntroAnimation {
    static let frameDuration = 0.45

    static let frames: [UIImage] = {
        guard let url = Bundle.main.url(forResource: "intro", withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        var images: [UIImage] = []
        for i in 0..<CGImageSourceGetCount(source) {
            if let cg = CGImageSourceCreateImageAtIndex(source, i, nil) {
                images.append(UIImage(cgImage: cg))
            }
        }
        return images
    }()

    static var totalDuration: Double { Double(frames.count) * frameDuration }
}

struct GIFPlayer: UIViewRepresentable {
    var fill = false

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let frames = IntroAnimation.frames
        view.image = frames.last // holds the logo after the last frame
        view.animationImages = frames
        view.animationDuration = IntroAnimation.totalDuration
        view.animationRepeatCount = 1
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
}

struct IntroView: View {
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let square = min(size.width * 1.6, size.height)
            ZStack {
                Color(red: 0, green: 0, blue: 0.016)

                // Blurred copy fills every edge of the screen with the glow
                GIFPlayer(fill: true)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 28)
                    .opacity(0.85)

                // Sharp animation, scaled up so the logo fills the width
                GIFPlayer()
                    .frame(width: square, height: square)
                    .mask(
                        RadialGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.62),
                                .init(color: .clear, location: 1)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: square * 0.52
                        )
                    )
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityLabel("CutFlow")
    }
}

/// Shows the intro, then fades into the app. Tap to skip.
struct RootView: View {
    @State private var showIntro = !IntroAnimation.frames.isEmpty

    var body: some View {
        ZStack {
            ContentView()
            if showIntro {
                IntroView()
                    .transition(.opacity)
                    .zIndex(1)
                    .onTapGesture { finish() }
            }
        }
        .task {
            let wait = IntroAnimation.totalDuration + 0.3
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            finish()
        }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.5)) { showIntro = false }
    }
}
