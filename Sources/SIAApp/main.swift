import SwiftUI
import AppKit
import SIACore

extension PhotoItem: Identifiable {}

@main
struct SIALiteApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Synology Image Daddy Converter") {
            RootView(state: state)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    if DemoMode.isOn { state.bootstrapDemo() }
                    if ProcessInfo.processInfo.environment["SIA_AUTOSTART"] == "1" {
                        // Retry until login finished; a fixed delay used to fire
                        // before the client existed and silently do nothing.
                        Task { @MainActor in
                            // Wait for the account, the cache and the ticked
                            // scope before starting, otherwise the queue is
                            // built from a half-initialised state.
                            for _ in 0..<30 {
                                // Wait for the root list too: the test scope hook
                                // runs in the same block, so this avoids racing it.
                                if !state.items.isEmpty, !state.selectedPaths.isEmpty,
                                   !state.rootFolders.isEmpty {
                                    break
                                }
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                            state.start()
                        }
                    }
                    if ProcessInfo.processInfo.environment["SIA_OPEN_ZERO"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                            state.collectZeroByteItems()
                            state.showZeroByteSheet = true
                        }
                    }
                    if let raw = ProcessInfo.processInfo.environment["SIA_OPEN_VIEWER"],
                       let id = Int(raw) {
                        // Test hook: open the viewer directly after the scan.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                            state.openViewer(id)
                        }
                    }
                    if ProcessInfo.processInfo.environment["SIA_OPEN_QUEUE"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            QueueWindowController.shared.show(state: state)
                        }
                    }
                    if state.accounts.count == 1, let only = state.accounts.first {
                        state.select(only)
                    } else if state.accounts.isEmpty {
                        state.showLogin = true
                    }
                }
        }
        .defaultSize(width: 1220, height: 780)
        .windowStyle(.titleBar)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra("Daddy", systemImage: "photo.stack") {
            Text(state.banner ?? "空闲")
            Divider()
            Button("显示窗口") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("扫描") { state.scan() }
            Button("开始") { state.start() }.disabled(state.isBusy)
            Button("停止") { state.stop() }.disabled(!state.isBusy)
            Button("任务队列") {
                NSApp.setActivationPolicy(.regular)
                QueueWindowController.shared.show(state: state)
            }
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        }
    }
}
