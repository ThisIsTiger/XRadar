// EventHistoryView.swift
import SwiftUI
import XRadarCore

struct EventHistoryView: View {
    @EnvironmentObject var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""

    var filteredEvents: [NotificationEvent] {
        if searchText.isEmpty {
            return appModel.events
        }
        return appModel.events.filter { event in
            event.body.localizedCaseInsensitiveContains(searchText) ||
            event.authorHandle.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索事件...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()

            if filteredEvents.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("暂无命中规则的通知事件")
                        .font(.headline)
                    Text("当监测账号发布新推文且触发关键词规则时，通知事件将保存在这里。\n想查看后台所有的推文抓取过程及匹配诊断，请打开“抓取历史”。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Button("打开“抓取历史与诊断” ➔") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "fetchHistory")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Event list
                List {
                    ForEach(filteredEvents) { event in
                        EventHistoryRow(event: event)
                            .contextMenu {
                                Button("在浏览器中打开") {
                                    NSWorkspace.shared.open(event.tweetURL)
                                }
                                Button("复制链接") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(event.tweetURL.absoluteString, forType: .string)
                                }
                                Divider()
                                Button("删除") {
                                    appModel.deleteEvent(event)
                                }
                            }
                    }
                }
                .listStyle(InsetListStyle())
                .radarFrostedBackdrop()
            }

            // Status bar
            HStack {
                Text("共 \(appModel.events.count) 个事件")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("导出日志") {
                    exportEvents()
                }
                .font(.caption)
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func exportEvents() {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "xradar_events_\(Date().timeIntervalSince1970).json"
        savePanel.allowedContentTypes = [.json]

        if savePanel.runModal() == .OK, let url = savePanel.url {
            Task {
                let events = await appModel.eventRepository.loadEvents()
                if let data = try? JSONEncoder().encode(events) {
                    try? data.write(to: url)
                }
            }
        }
    }
}

struct EventHistoryRow: View {
    @EnvironmentObject var appModel: AppModel
    let event: NotificationEvent

    private var ruleName: String? {
        for ruleID in event.matchedRuleIDs {
            if let rule = appModel.configuration.rules.first(where: { $0.id == ruleID }),
               !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rule.name
            }
        }
        if let rule = appModel.configuration.rules.first(where: { $0.accountHandle.lowercased() == event.authorHandle.lowercased() }),
           !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rule.name
        }
        if !event.title.hasPrefix("@") && !event.title.isEmpty {
            return event.title
        }
        return nil
    }

    private func friendlyErrorText(_ rawError: String) -> String {
        if rawError.contains("UNErrorDomain error 1") || rawError.contains("notificationsNotAllowed") {
            return "macOS 系统通知权限未开启（请在 系统设置 -> 通知 中允许 XRadar）"
        }
        return rawError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let name = ruleName {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                    Text("@\(event.authorHandle)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("@\(event.authorHandle)")
                        .font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Text(event.createdAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !event.matchedKeywords.isEmpty {
                HStack(spacing: 4) {
                    ForEach(event.matchedKeywords, id: \.self) { keyword in
                        Text(keyword)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
            }

            Text(event.body)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundColor(.primary)

            HStack {
                // Check if any channel succeeded
                let hasSuccess = event.channelResults.values.contains(where: { $0.success })
                Image(systemName: hasSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(hasSuccess ? .green : .red)
                    .font(.caption)

                // Show first error if any
                let firstError = event.channelResults.values.compactMap { $0.success ? nil : $0.errorMessage }.first
                if let error = firstError {
                    Text(friendlyErrorText(error))
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}
