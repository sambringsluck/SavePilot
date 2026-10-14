import AppKit
import SwiftUI

@main
struct SavePilotApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("SavePilot", id: "review") {
            ReviewView()
                .environmentObject(model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    model.refreshPermissions()
                }
                .onReceive(NotificationCenter.default.publisher(for: .showReviewWindow)) { _ in
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshPermissions()
                }
        }
        .defaultSize(width: 920, height: 620)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.pendingCount > 0 ? "tray.full.fill" : "tray")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
