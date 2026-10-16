// SourceSettingsView.swift
import SwiftUI
import XRadarCore

struct SourceSettingsView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var newInstanceInput = ""
    @State private var instanceError: String?
    @State private var testAccount = ""
    @State private var testResult: SourceTestResult = SourceTestResult()
    @State private var isTesting = false

    private var ruleAccounts: [String] {
        // 只列 X 账号规则；RSS 源规则的显示名对 RSSHub Twitter 路由无意义。
        Array(Set(appModel.configuration.rules.filter { $0.feedURL == nil }.map(\.accountHandle))).sorted()
    }

    var body: some View {
        Form {
            Section("当前信源状态") {
                Label {
                    Text(appModel.sourceHealthSummary)
                        .foregroundColor(.primary)
                } icon: {
                    Image(systemName: sourceHealthIcon)
                        .foregroundColor(sourceHealthColor)
                }
            }

            Section("抓取策略") {
                Picker("抓取策略", selection: Binding(
                    get: { appModel.configuration.xSourceSettings.policy },
                    set: { appModel.updateSourcePolicy($0) }
                )) {
                    ForEach(XSourcePolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)

                if appModel.configuration.xSourceSettings.policy == .rssHubOnly {
                    Text("RSSHub 抓取不需要登录 X；X 登录入口已弱化。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if appModel.configuration.xSourceSettings.policy == .rssHubThenXWeb {
                Section {
                    Toggle(
                        "我已了解风险：RSSHub 全部失败时本应用会使用内置浏览器访问 X 抓取，存在账号被风控的风险",
                        isOn: Binding(
                            get: { appModel.configuration.xSourceSettings.webFallbackRiskAcknowledged },
                            set: { appModel.setWebFallbackRiskAcknowledged($0) }
                        )
                    )
                    if !appModel.configuration.xSourceSettings.webFallbackRiskAcknowledged {
                        Text("未确认风险前无法启用自动回退（不会保存该策略）。")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                } header: {
                    Text("自动回退 X 的风险确认")
                }
            }

            Section("RSSHub 实例") {
                HStack {
                    TextField("https://…", text: $newInstanceInput)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        instanceError = appModel.addRSSHubInstance(newInstanceInput)
                        if instanceError == nil {
                            newInstanceInput = ""
                        }
                    }
                    .disabled(newInstanceInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let instanceError {
                    Text(instanceError)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if appModel.configuration.xSourceSettings.rssHubInstances.isEmpty {
                    Text("尚未配置实例。应用不内置任何实例推荐，请添加自建（http://localhost:1200）或自行确认可用的实例地址。未配置时自动与手动抓取都不会执行。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appModel.configuration.xSourceSettings.rssHubInstances, id: \.self) { instance in
                        HStack {
                            Button {
                                appModel.moveRSSHubInstance(
                                    fromOffsets: IndexSet(
                                        integer: appModel.configuration.xSourceSettings.rssHubInstances.firstIndex(of: instance) ?? 0
                                    ),
                                    toOffset: max(0, (appModel.configuration.xSourceSettings.rssHubInstances.firstIndex(of: instance) ?? 0) - 1)
                                )
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .accessibilityLabel("上移实例 \(instance)")
                            .disabled(appModel.configuration.xSourceSettings.rssHubInstances.first == instance)

                            Button {
                                let index = appModel.configuration.xSourceSettings.rssHubInstances.firstIndex(of: instance) ?? 0
                                appModel.moveRSSHubInstance(
                                    fromOffsets: IndexSet(integer: index),
                                    toOffset: min(index + 2, appModel.configuration.xSourceSettings.rssHubInstances.count)
                                )
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .accessibilityLabel("下移实例 \(instance)")
                            .disabled(appModel.configuration.xSourceSettings.rssHubInstances.last == instance)

                            Text(instance)
                                .textSelection(.enabled)

                            Spacer()

                            Button(role: .destructive) {
                                appModel.removeRSSHubInstance(instance)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("删除实例 \(instance)")
                        }
                    }
                }
            }

            Section("实例说明") {
                Text("第三方实例的运营者可以看到你查询的账号。公共实例大多已停用 Twitter 路由，请使用自己确认可用的实例（如自建）并通过「测试信源」验证。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("测试信源") {
                Picker("测试账号", selection: $testAccount) {
                    Text("选择规则账号…").tag("")
                    ForEach(ruleAccounts, id: \.self) { account in
                        Text("@\(account)").tag(account)
                    }
                }
                .disabled(ruleAccounts.isEmpty)

                HStack {
                    Button("测试信源") {
                        isTesting = true
                        testResult = SourceTestResult()
                        Task {
                            testResult = await appModel.testSource(accountHandle: testAccount)
                            isTesting = false
                        }
                    }
                    .disabled(testAccount.isEmpty || isTesting
                              || appModel.configuration.xSourceSettings.rssHubInstances.isEmpty)

                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }

                if testResult.error != nil || testResult.statusCode != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        if let host = testResult.instanceHost {
                            HStack {
                                Text("实例 host")
                                Spacer()
                                Text(host).foregroundColor(.secondary)
                            }
                        }
                        if let status = testResult.statusCode {
                            HStack {
                                Text("HTTP 状态")
                                Spacer()
                                Text("\(status)").foregroundColor(.secondary)
                            }
                        }
                        if let raw = testResult.rawItemCount {
                            HStack {
                                Text("原始条目数")
                                Spacer()
                                Text("\(raw)").foregroundColor(.secondary)
                            }
                        }
                        if let valid = testResult.validTweetCount {
                            HStack {
                                Text("有效条目数")
                                Spacer()
                                Text("\(valid)").foregroundColor(.secondary)
                            }
                        }
                        if let latest = testResult.latestPublishedAt {
                            HStack {
                                Text("最新发布时间")
                                Spacer()
                                Text(latest.formatted(.dateTime.year().month().day().hour().minute()))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let duration = testResult.duration {
                            HStack {
                                Text("耗时")
                                Spacer()
                                Text(String(format: "%.2f 秒", duration)).foregroundColor(.secondary)
                            }
                        }
                if let error = testResult.error {
                    HStack {
                        Text("错误")
                        Spacer()
                        Text(error)
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                    Text("提示：公共 RSSHub 实例大多已停用 Twitter 路由。可在上方切换到「应用内 X 登录抓取」，并在「X 账号」页登录一次；该模式无需任何实例。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                    }
                    .font(.caption)
                }
                Text("测试只抓取一次并解析，不写 Cursor、历史或事件，也不会发送通知或回退 WebView。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .radarFrostedBackdrop()
        .padding()
    }

    private var sourceHealthIcon: String {
        switch appModel.sourceHealthSummary {
        case _ where !appModel.configuration.xSourceSettings.sourceSetupCompleted:
            return "exclamationmark.triangle"
        case _ where appModel.configuration.xSourceSettings.rssHubInstances.isEmpty:
            return "exclamationmark.triangle"
        default:
            return "checkmark.circle"
        }
    }

    private var sourceHealthColor: Color {
        switch appModel.sourceHealthSummary {
        case _ where !appModel.configuration.xSourceSettings.sourceSetupCompleted:
            return .orange
        case _ where appModel.configuration.xSourceSettings.rssHubInstances.isEmpty:
            return .orange
        default:
            return .green
        }
    }
}