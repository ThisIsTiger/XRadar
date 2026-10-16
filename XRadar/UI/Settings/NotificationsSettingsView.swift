// NotificationsSettingsView.swift
import SwiftUI
import XRadarCore

struct NotificationsSettingsView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var telegramToken: String = ""
    @State private var telegramChatID: String = ""
    @State private var testResult: String? = nil

    var body: some View {
        Form {
            Section("macOS 通知") {
                Toggle("启用 macOS 通知", isOn: Binding(
                    get: { appModel.configuration.macOSNotificationsEnabled },
                    set: { appModel.setMacOSNotificationsEnabled($0) }
                ))

                Toggle("启用通知声音", isOn: Binding(
                    get: { appModel.configuration.macOSNotificationSoundEnabled },
                    set: { appModel.setMacOSNotificationSoundEnabled($0) }
                ))

                Button("发送测试通知") {
                    Task {
                        let result = await appModel.notificationGateway.sendTest(to: .macOS)
                        testResult = result.success ? "测试通知已发送" : (result.errorMessage ?? "发送失败")
                    }
                }
            }

            Section("Telegram Bot") {
                Toggle("启用 Telegram 通知", isOn: Binding(
                    get: { appModel.configuration.telegramEnabled },
                    set: { appModel.setTelegramEnabled($0) }
                ))

                SecureField("Bot Token", text: $telegramToken)
                    .textFieldStyle(.roundedBorder)

                SecureField("Chat ID", text: $telegramChatID)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("保存 Telegram 设置") {
                        saveTelegramSettings()
                    }
                    .disabled(!telegramInputComplete)

                    Button("发送测试消息") {
                        Task {
                            await testTelegram()
                        }
                    }
                }

                if !telegramInputComplete {
                    Text("Bot Token 和 Chat ID 均不能为空（防止空值覆盖已保存的凭据）。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(result.contains("失败") ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .radarFrostedBackdrop()
        .padding()
        .onAppear {
            loadTelegramSettings()
        }
    }

    /// 空字段禁止保存：Keychain 读取瞬时失败时字段为空，直接保存会覆盖真实凭据。
    private var telegramInputComplete: Bool {
        !telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadTelegramSettings() {
        Task {
            do {
                telegramToken = try await KeychainStore.shared.loadTelegramBotToken()
            } catch {
                telegramToken = ""
            }

            do {
                telegramChatID = try await KeychainStore.shared.loadTelegramChatID()
            } catch {
                telegramChatID = ""
            }
        }
    }

    private func saveTelegramSettings() {
        Task {
            do {
                try await KeychainStore.shared.saveTelegramBotToken(telegramToken)
                try await KeychainStore.shared.saveTelegramChatID(telegramChatID)
                testResult = "Telegram 设置已保存"
            } catch {
                testResult = "保存失败: \(error.localizedDescription)"
            }
        }
    }

    private func testTelegram() async {
        let result = await appModel.notificationGateway.sendTest(to: .telegram)
        testResult = result.success ? "测试消息已发送" : (result.errorMessage ?? "发送失败")
    }
}
