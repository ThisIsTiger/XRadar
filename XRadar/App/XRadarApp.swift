// XRadarApp.swift
import SwiftUI
import XRadarCore

@main
struct XRadarApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("XRadar 控制台", id: "main") {
            SettingsView()
                .environmentObject(appModel)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appModel)
        } label: {
            MenuBarIconView(status: appModel.runtimeState.status)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }

        WindowGroup("设置", id: "settings") {
            SettingsView()
                .environmentObject(appModel)
        }

        WindowGroup("历史事件", id: "events") {
            EventHistoryView()
                .environmentObject(appModel)
        }

        WindowGroup("抓取历史与诊断", id: "fetchHistory") {
            FetchHistoryView()
                .environmentObject(appModel)
        }
    }
}

struct MenuBarIconView: View {
    let status: AppRunStatus

    var body: some View {
        Image(systemName: iconName)
            .foregroundColor(iconColor)
    }

    private var iconName: String {
        switch status {
        case .paused:
            return "pause.circle"
        case .loginRequired:
            return "exclamationmark.triangle"
        case .actionRequired:
            return "exclamationmark.triangle"
        case .backingOff:
            return "sleep"
        case .configurationRequired:
            return "exclamationmark.triangle"
        default:
            return "antenna.radiowaves.left.and.right"
        }
    }

    private var iconColor: Color {
        switch status {
        case .paused, .backingOff, .configurationRequired:
            return .orange
        case .loginRequired, .actionRequired:
            return .red
        case .degraded:
            return .yellow
        default:
            return .primary
        }
    }
}
