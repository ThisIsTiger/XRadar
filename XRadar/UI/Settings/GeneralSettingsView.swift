// GeneralSettingsView.swift
import SwiftUI
import os.log
import XRadarCore
import ServiceManagement

struct GeneralSettingsView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var showingResetConfirmation = false
    @State private var showingClearHistoryConfirmation = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动", isOn: Binding(
                    get: { appModel.configuration.launchAtLogin },
                    set: { newValue in
                        appModel.setLaunchAtLogin(enabled: newValue)
                        setLaunchAtLoginService(enabled: newValue)
                    }
                ))
            }

            Section("历史记录") {
                Picker("历史保留天数", selection: Binding(
                    get: { appModel.configuration.historyRetentionDays },
                    set: { appModel.setHistoryRetentionDays($0) }
                )) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                }

                Picker("最近事件上限", selection: Binding(
                    get: { appModel.configuration.maxRecentEvents },
                    set: { appModel.setMaxRecentEvents($0) }
                )) {
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                }

                Text("保留天数与上限作用于通知事件；抓取诊断记录固定保留最近 3 天窗口。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("清除事件历史") {
                    showingClearHistoryConfirmation = true
                }
                .alert("确认清除", isPresented: $showingClearHistoryConfirmation) {
                    Button("取消", role: .cancel) { }
                    Button("清除", role: .destructive) {
                        Task {
                            await appModel.eventRepository.saveEvents([])
                            await appModel.reloadEvents()
                        }
                    }
                } message: {
                    Text("这将清除所有事件历史记录。此操作不可撤销。")
                }
            }

            Section("诊断") {
                Button("导出诊断日志") {
                    exportDiagnostics()
                }

                Button("重置应用") {
                    showingResetConfirmation = true
                }
                .foregroundColor(.red)
                .alert("确认重置", isPresented: $showingResetConfirmation) {
                    Button("取消", role: .cancel) { }
                    Button("重置", role: .destructive) {
                        resetApplication()
                    }
                } message: {
                    Text("这将清除所有设置、规则和事件历史。Telegram 配置也将被删除。此操作不可撤销。")
                }
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(appVersionText)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .radarFrostedBackdrop()
        .padding()
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func setLaunchAtLoginService(enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                Logger(subsystem: "com.xradar.app", category: "GeneralSettings").error("Failed to set launch at login: \(error.localizedDescription)")
            }
        }
    }

    private func exportDiagnostics() {
        // Simple diagnostics export - saves basic app info
        let diagnosticsInfo: [String: String] = [
            "appVersion": appVersionText,
            "buildDate": ISO8601DateFormatter().string(from: Date()),
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: diagnosticsInfo, options: .prettyPrinted)
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = "XRadar-Diagnostics.json"

            savePanel.begin { result in
                guard result == .OK, let url = savePanel.url else { return }
                try? jsonData.write(to: url)
            }
        } catch {
            Logger(subsystem: "com.xradar.app", category: "GeneralSettings").error("Failed to export diagnostics: \(error.localizedDescription)")
        }
    }

    private func resetApplication() {
        Task {
            // Clear all data
            appModel.configuration = AppConfiguration.default
            appModel.runtimeState = RuntimeState.default
            await appModel.eventRepository.saveEvents([])
            await appModel.fetchHistoryRepository.clear()

            // Clear Telegram credentials
            try? await KeychainStore.shared.deleteTelegramCredentials()

            // Clear WebKit data
            try? await appModel.xSession.logout()

            // Persist defaults so the reset survives restart, then refresh UI.
            await appModel.configRepository.save(appModel.configuration)
            await appModel.stateRepository.save(appModel.runtimeState)
            await appModel.reloadEvents()
            await appModel.reloadFetchRecords()
        }
    }
}
