import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct VitalsLoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = MonitorViewModel(store: HistoryStore())
    @AppStorage("safetyNoticeAcceptedVersion") private var safetyNoticeAcceptedVersion = 0

    var body: some Scene {
        WindowGroup("VitalsLoom") {
            Group {
                if safetyNoticeAcceptedVersion >= 1 {
                    MonitorView()
                        .environment(monitor)
                } else {
                    SafetyNoticeView {
                        safetyNoticeAcceptedVersion = 1
                    }
                }
            }
            .frame(minWidth: 940, minHeight: 610)
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(monitor)
                .frame(width: 760, height: 680)
        }
    }
}
