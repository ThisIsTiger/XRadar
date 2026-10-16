import SwiftUI
import XRadarCore

struct FetchHistoryView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var accountFilter = "全部账号"
    @State private var outcomeFilter = "all"
    @State private var searchText = ""
    @State private var showingClearConfirmation = false

    private var accounts: [String] {
        Array(Set(appModel.fetchRecords.map(\.accountHandle))).sorted()
    }

    private var filteredRecords: [FetchRecord] {
        appModel.fetchRecords.filter { record in
            let accountMatches = accountFilter == "全部账号" || record.accountHandle == accountFilter
            let outcomeMatches = outcomeFilter == "all" || record.outcome.rawValue == outcomeFilter
            let searchMatches = searchText.isEmpty ||
                record.text.localizedCaseInsensitiveContains(searchText) ||
                record.matchedRuleNames.contains {
                    $0.localizedCaseInsensitiveContains(searchText)
                }
            return accountMatches && outcomeMatches && searchMatches
        }.sorted {
            let lhsDate = $0.publishedAt ?? $0.fetchedAt
            let rhsDate = $1.publishedAt ?? $1.fetchedAt
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return ($0.tweetID ?? "") > ($1.tweetID ?? "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if filteredRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("暂无抓取记录")
                        .font(.headline)
                    Text("保存规则后点击“立即检查”。首次抓取会显示为“首次基线”。")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredRecords) { record in
                    FetchRecordRow(record: record)
                }
                .listStyle(.inset)
                .radarFrostedBackdrop()
            }
        }
        .task {
            await appModel.reloadFetchRecords()
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("账号", selection: $accountFilter) {
                    Text("全部账号").tag("全部账号")
                    ForEach(accounts, id: \.self) { account in
                        Text("@\(FetchRecordDisplay.name(for: account))").tag(account)
                    }
                }
                .frame(width: 210)

                Picker("结果", selection: $outcomeFilter) {
                    Text("全部结果").tag("all")
                    ForEach(FetchOutcome.allCases, id: \.self) { outcome in
                        Text(outcome.displayName).tag(outcome.rawValue)
                    }
                }
                .frame(width: 210)

                TextField("搜索正文或规则", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task {
                        await appModel.reloadFetchRecords()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Button("清空", role: .destructive) {
                    showingClearConfirmation = true
                }
                .disabled(appModel.fetchRecords.isEmpty)
            }

            HStack {
                Text("共 \(filteredRecords.count) 条")
                    .foregroundColor(.secondary)
                Spacer()
                Text("首次基线不会发送通知；只有新的、命中规则的推文才会通知。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .alert("清空抓取记录？", isPresented: $showingClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                appModel.clearFetchHistory()
            }
        } message: {
            Text("这只清空诊断记录，不会重置推文去重状态。")
        }
    }
}

private struct FetchRecordRow: View {
    let record: FetchRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("@\(record.accountDisplayName)")
                    .fontWeight(.semibold)
                if let tweetKind = record.tweetKind {
                    Text(tweetKind.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                OutcomeBadge(outcome: record.outcome)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if record.tweetID != nil {
                        Text(
                            "发推：\(record.publishedAt?.formatted(.dateTime.year().month().day().hour().minute().second()) ?? "未知")"
                        )
                    }
                    Text(
                        "抓取：\(record.fetchedAt.formatted(.dateTime.year().month().day().hour().minute().second()))"
                    )
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Text(record.text.isEmpty ? "（无文字内容）" : record.text)
                .textSelection(.enabled)

            if let providerDescription = record.sourceDescription {
                Label {
                    Text(providerDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } icon: {
                    Image(systemName: record.providerID == .rssHub ? "antenna.radiowaves.left.and.right" : "globe")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !record.matchedRuleNames.isEmpty {
                Text("命中规则：\(record.matchedRuleNames.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            if !record.matchedKeywords.isEmpty {
                Text("命中关键词：\(record.matchedKeywords.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            HStack {
                if let tweetID = record.tweetID {
                    Text("Tweet ID：\(tweetID)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let tweetURL = record.tweetURL {
                    Button("打开原推") {
                        var finalURL = tweetURL
                        if let components = URLComponents(url: tweetURL, resolvingAgainstBaseURL: false),
                           components.host == "x.com" {
                            var newComponents = components
                            newComponents.host = "twitter.com"
                            if let newURL = newComponents.url {
                                finalURL = newURL
                            }
                        }
                        NSWorkspace.shared.open(finalURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct OutcomeBadge: View {
    let outcome: FetchOutcome

    var body: some View {
        Text(outcome.displayName)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch outcome {
        case .baseline:
            return .blue
        case .historical:
            return .purple
        case .previouslySeen:
            return .gray
        case .notMatched:
            return .orange
        case .matched:
            return .green
        case .fetchFailed:
            return .red
        case .noNewTweets:
            return .gray
        }
    }
}

private extension TweetKind {
    var displayName: String {
        switch self {
        case .original:
            return "原创"
        case .reply:
            return "回复"
        case .repost:
            return "转发"
        case .unknown:
            return "未知"
        }
    }
}

private extension FetchRecord {
    /// Provider / 实例 host / 回退来源 的展示文案（DESIGN-RSSHUB.md §10.3）。
    var sourceDescription: String? {
        guard let providerID else { return nil }
        switch providerID {
        case .rssHub:
            var text = "信源：RSSHub"
            if let instanceHost {
                text += " · \(instanceHost)"
            }
            if fallbackFromProviderID != nil {
                text += " · 由 RSSHub 回退至 X WebView"
            }
            return text
        case .xWeb:
            var text = "信源：X WebView"
            if let fallback = fallbackFromProviderID {
                text += " · 由 \(fallback.displayName) 回退"
            }
            return text
        case .rssFeed:
            var text = "信源：自定义 RSS"
            if let instanceHost {
                text += " · \(instanceHost)"
            }
            return text
        }
    }
}
