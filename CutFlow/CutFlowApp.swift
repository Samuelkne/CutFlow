import SwiftUI

@main
struct CutFlowApp: App {
    init() {
        Prefs.register()   // default settings, before anything reads them
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

extension Color {
    static let rcBlue = Color(red: 0.0, green: 0.35, blue: 1.0)
    static let rcBlack = Color(red: 0.05, green: 0.05, blue: 0.07)
}
