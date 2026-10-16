// MenuBarView.swift
import SwiftUI
import XRadarCore

struct MenuBarView: View {
    @EnvironmentObject var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var expandedRules: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerView

            Divider()

            // Rules List
            rulesListView

            Divider()

            // Actions
            actionsView
        }
        .frame(width: 360)
        .padding(.vertical, 8)
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("XRadar")
                    .font(.headline)
                Spacer()
                StatusBadge(status: appModel.runtimeState.status)
            }

            statusDetailView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// 状态提示区：需要用户处理的状态（配置/登录/退避/异常）可点击直达对应
    /// 设置 tab；正常状态为纯展示。
    @ViewBuilder
    private var statusDetailView: some View {
        let detail = statusDetailText
        if let tabIndex = appModel.runtimeState.status.suggestedSettingsTabIndex {
            Button {
                UserDefaults.standard.set(tabIndex, forKey: "settings.selectedTab")
                openSettingsWindow()
            } label: {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("前往处理：\(appModel.runtimeState.status.displayName)")
            .help("点击前往对应设置")
        } else {
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isChecking: Bool {
        if case .running = appModel.runtimeState.status { return true }
        return false
    }

    private var manualCheckBlockedReason: String? {
        appModel.runtimeState.status.manualCheckBlockedReason
    }

    private var statusDetailText: String {
        let ruleCount = appModel.configuration.rules.count
        let enabledCount = appModel.configuration.rules.filter(\.enabled).count
        var detail = "\(appModel.runtimeState.status.displayName) · \(enabledCount)/\(ruleCount) 个规则"

        if let summary = appModel.runtimeState.lastRunSummary {
            let timeStr = summary.finishedAt.formatted(.dateTime.hour().minute().second())
            detail += "\n上次检查 \(timeStr)：抓取 \(summary.tweetsFound) 条，命中 \(summary.eventsGenerated) 条"
        }

        // 下次检查提示：退避中显示真实截止时间，否则按间隔估算，
        // 让"安静的等待"与"调度已停"可被区分。
        if let backoff = appModel.runtimeState.backoffUntil, backoff > Date() {
            detail += "\n下次检查 \(backoff.formatted(.dateTime.hour().minute().second()))（退避中）"
        } else if !appModel.runtimeState.isPaused,
                  let lastRunAt = appModel.runtimeState.lastRunAt {
            let estimate = lastRunAt.addingTimeInterval(
                TimeInterval(appModel.configuration.pollInterval.rawValue)
            )
            if estimate > Date() {
                detail += "\n下次检查 ≈\(estimate.formatted(.dateTime.hour().minute().second()))"
            }
        }
        return detail
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private var rulesListView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("抓取规则")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if appModel.configuration.rules.isEmpty {
                    Button("添加规则") {
                        openSettingsWindow()
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                } else {
                    Button("管理") {
                        openSettingsWindow()
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if appModel.configuration.rules.isEmpty {
                Text("暂无抓取规则")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            } else {
                ForEach(appModel.configuration.rules) { rule in
                    MenuBarRuleRow(
                        rule: rule,
                        isExpanded: Binding(
                            get: { expandedRules.contains(rule.id) },
                            set: { isExpanded in
                                if isExpanded {
                                    expandedRules.insert(rule.id)
                                } else {
                                    expandedRules.remove(rule.id)
                                }
                            }
                        ),
                        records: appModel.fetchRecords.filter {
                            $0.belongsTo(rule: rule)
                        }.sorted {
                            let lhsDate = $0.publishedAt ?? $0.fetchedAt
                            let rhsDate = $1.publishedAt ?? $1.fetchedAt
                            if lhsDate != rhsDate {
                                return lhsDate > rhsDate
                            }
                            return ($0.tweetID ?? "") > ($1.tweetID ?? "")
                        }
                    )
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var actionsView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Button("立即检查") {
                    appModel.triggerNow()
                }
                .disabled(isChecking || manualCheckBlockedReason != nil)
                .help(manualCheckBlockedReason ?? "")

                if let reason = manualCheckBlockedReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Button(appModel.runtimeState.isPaused ? "恢复" : "暂停") {
                appModel.togglePause()
            }

            Spacer()

            Menu("更多") {
                Button("历史事件记录...") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "events")
                }

                Button("抓取历史与诊断...") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "fetchHistory")
                }

                Divider()

                Button("设置...") {
                    openSettingsWindow()
                }

                Button("登录 X") {
                    NSApp.activate(ignoringOtherApps: true)
                    appModel.presentLogin()
                }

                Divider()

                Button("退出") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct StatusBadge: View {
    let status: AppRunStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            
                        .foregroundStyle(statusTint)
            .background(statusTint.opacity(0.12), in: .capsule)
            .overlay(Capsule().strokeBorder(statusTint.opacity(0.35), lineWidth: 0.8))
    }

    private var statusTint: Color {
        switch status {
        case .idle:
            return .green
        case .running:
            return .blue
        case .paused:
            return .orange
        case .loginRequired, .actionRequired:
            return .red
        case .backingOff:
            return .yellow
        case .degraded:
            return .gray
        case .configurationRequired:
            return .orange
        }
    }
}

struct MenuBarRuleRow: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var appModel: AppModel
    let rule: MonitorRule
    @Binding var isExpanded: Bool
    let records: [FetchRecord]

    private var hasRecentMatch: Bool {
        records.prefix(5).contains { $0.outcome == .matched }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: {
                    withAnimation { isExpanded.toggle() }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 12)

                        Text(rule.name.isEmpty ? "@\(rule.accountHandle)" : rule.name)
                            .font(.subheadline)
                            .foregroundColor(hasRecentMatch ? .orange : .primary)

                        if !rule.name.isEmpty {
                            Text("@\(rule.accountHandle)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "收起" : "展开")规则 \(rule.name.isEmpty ? rule.accountHandle : rule.name)")
                .accessibilityHint("最近有命中时规则名会显示为橙色")

                Spacer()

                Toggle("启用规则", isOn: Binding(
                    get: { rule.enabled },
                    set: { newValue in
                        var updatedRule = rule
                        updatedRule.enabled = newValue
                        appModel.updateRule(updatedRule)
                    }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.7)
                .labelsHidden()
                .accessibilityLabel("启用规则 \(rule.name.isEmpty ? rule.accountHandle : rule.name)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(isExpanded ? 0.5 : 0))

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    let recentRecords = Array(records.prefix(5))
                    if recentRecords.isEmpty {
                        Text("暂无抓取记录")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 34)
                            .padding(.vertical, 4)
                    } else {                        ForEach(recentRecords) { record in
                            HStack(alignment: .top, spacing: 8) {
                                MenuBarOutcomeBadge(outcome: record.outcome)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(record.fetchedAt, style: .time)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)

                                        if let published = record.publishedAt {
                                            Text("发推: ")
                                                .font(.caption2)
                                                .foregroundColor(.secondary) +
                                            Text(published, style: .time)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    if !record.text.isEmpty {
                                        Text(record.text)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .lineLimit(2)
                                    }
                                }

                                Spacer()

                                if record.tweetURL != nil {
                                    Image(systemName: "arrow.up.forward.app")
                                        .foregroundColor(Color.secondary.opacity(0.5))
                                        .font(.caption2)
                                        .padding(.top, 4)
                                }
                            }
                            .padding(.leading, 34)
                            .padding(.trailing, 16)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let url = record.tweetURL {
                                    var finalURL = url
                                    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                                       components.host == "x.com" {
                                        var newComponents = components
                                        newComponents.host = "twitter.com"
                                        if let newURL = newComponents.url {
                                            finalURL = newURL
                                        }
                                    }
                                    NSWorkspace.shared.open(finalURL)
                                }
                            }

                            if record.id != recentRecords.last?.id {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("查看全部诊断历史 ➔") {
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "fetchHistory")
                        }
                        .font(.caption2)
                        .buttonStyle(.link)
                        .padding(.trailing, 16)
                        .padding(.bottom, 6)
                    }
                }
                .radarGlassCard(cornerRadius: 10)
            }
        }
    }
}

struct MenuBarOutcomeBadge: View {
    let outcome: FetchOutcome

    var body: some View {
        Text(outcomeDisplayName)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private var outcomeDisplayName: String {
        switch outcome {
        case .baseline: return "首次基线"
        case .historical: return "历史补录"
        case .previouslySeen: return "已处理"
        case .notMatched: return "未命中"
        case .matched: return "命中"
        case .fetchFailed: return "失败"
        case .noNewTweets: return "暂无新推"
        }
    }

    private var color: Color {
        switch outcome {
        case .baseline: return .blue
        case .historical: return .purple
        case .previouslySeen: return .gray
        case .notMatched: return .orange
        case .matched: return .green
        case .fetchFailed: return .red
        case .noNewTweets: return .gray
        }
    }
}
