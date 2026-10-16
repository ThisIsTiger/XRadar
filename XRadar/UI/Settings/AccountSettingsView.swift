// AccountSettingsView.swift
import SwiftUI
import XRadarCore

struct AccountSettingsView: View {
    @EnvironmentObject var appModel: AppModel

    /// rssHubOnly 时登录入口弱化（DESIGN-RSSHUB.md §10.2）。
    private var loginNotRequired: Bool {
        appModel.configuration.xSourceSettings.policy == .rssHubOnly
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("登录状态")
                    Spacer()
                    Text(appModel.xSession.state.displayText)
                        .foregroundColor(.secondary)
                }

                if case .loggedIn(let handle) = appModel.xSession.state, let handle = handle {
                    HStack {
                        Text("当前账号")
                        Spacer()
                        Text("@\(handle)")
                            .foregroundColor(.secondary)
                    }
                }
            }

            if loginNotRequired {
                Section("X 登录") {
                    Label {
                        Text("当前信源为 RSSHub，不需要登录 X。")
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "shield")
                            .foregroundColor(.secondary)
                    }

                    Button("仍然登录 X") {
                        appModel.presentLogin()
                    }
                    .disabled(appModel.xSession.state.isLoggedIn)

                    Button("退出登录") {
                        appModel.logout()
                    }
                    .disabled(!appModel.xSession.state.isLoggedIn)
                }
            } else {
                Section {
                    Button("登录 X") {
                        appModel.presentLogin()
                    }
                    .disabled(appModel.xSession.state.isLoggedIn)

                    Button("打开 X") {
                        if let url = URL(string: "https://x.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    Button("重新登录") {
                        appModel.logout()
                        appModel.presentLogin()
                    }
                    .disabled(!appModel.xSession.state.isLoggedIn)

                    Button("退出登录") {
                        appModel.logout()
                    }
                    .disabled(!appModel.xSession.state.isLoggedIn)
                }
            }
        }
        .formStyle(.grouped)
        .radarFrostedBackdrop()
        .padding()
    }
}
