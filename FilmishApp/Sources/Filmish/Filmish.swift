import AppKit
import SwiftUI

@main
struct FilmishApplication: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Filmish") {
            ContentView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .frame(minWidth: 1080, minHeight: 740)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Filmish") {
                    showAboutPanel()
                }
            }
            CommandGroup(replacing: .newItem) { }
        }
    }

    private func showAboutPanel() {
        let icon: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSApplication.shared.applicationIconImage
            ?? NSImage(size: NSSize(width: 128, height: 128))

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 3

        let credits = NSAttributedString(
            string: "Filmish — technically a movie, probably.\n\nA friendly GUI for FFmpeg, built with vibe coding and ChatGPT by Tõnis Kaumann — who knows absolutely nothing about programming. Somehow, that did not stop the app from working.\n\nTurn your images into frame-accurate MP4 slideshows, arrange them by dragging, and add transitions and fades without touching the Terminal.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Filmish",
            .applicationIcon: icon,
            .applicationVersion: "1.2",
            .version: "3",
            .credits: credits,
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
