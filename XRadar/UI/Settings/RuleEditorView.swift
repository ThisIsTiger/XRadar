// RuleEditorView.swift
import SwiftUI
import XRadarCore

struct RuleEditorView: View {
    @State var rule: MonitorRule?
    /// Sheet 模式提供取消入口；detail 模式可为 nil。
    var onCancel: (() -> Void)? = nil
    let onSave: (MonitorRule) -> Void

    @State private var justSaved = false

    @State private var name: String = ""
    @State private var accountHandle: String = ""
    @State private var feedURL: String = ""
    @State private var isFeedRule: Bool = false
    @State private var enabled: Bool = true
    @State private var triggerMode: TriggerMode = .keywords
    @State private var includeKeywords: [String] = []
    @State private var excludeKeywords: [String] = []
    @State private var keywordMatchMode: KeywordMatchMode = .any
    @State private var caseSensitive: Bool = false
    @State private var includeReplies: Bool = false
    @State private var includeReposts: Bool = false
    @State private var notificationChannels: Set<NotificationChannelID> = [.macOS]

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("规则名称", text: $name)
                Picker("源类型", selection: $isFeedRule) {
                    Text("X 账号").tag(false)
                    Text("自定义 RSS 源").tag(true)
                }
                if isFeedRule {
                    TextField("RSS 源地址 (https://…)", text: $feedURL)
                    if !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !draftRule.isConfigured {
                        Text("地址无效：需要绝对 http(s) URL，且不能是 x.com/twitter.com 域名")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    TextField("源名称（显示用，如站点名）", text: $accountHandle)
                } else {
                    TextField("X 账号 (例如: elonmusk)", text: $accountHandle)
                }
                Toggle("启用", isOn: $enabled)
            }

            Section("触发条件") {
                Picker("触发模式", selection: $triggerMode) {
                    ForEach(TriggerMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if triggerMode == .keywords {
                    Picker("匹配模式", selection: $keywordMatchMode) {
                        ForEach(KeywordMatchMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Toggle("区分大小写", isOn: $caseSensitive)
                }
            }

            if triggerMode == .keywords {
                Section("正向关键词") {
                    KeywordTagEditor(keywords: $includeKeywords)
                }

                Section("排除关键词") {
                    KeywordTagEditor(keywords: $excludeKeywords)
                }
            }

            if !isFeedRule {
                Section("选项") {
                    Toggle("包含回复", isOn: $includeReplies)
                    Toggle("包含转发", isOn: $includeReposts)
                }
            }

            Section("通知渠道") {
                ForEach(NotificationChannelID.allCases, id: \.self) { channel in
                    Toggle(channel.displayName, isOn: Binding(
                        get: { notificationChannels.contains(channel) },
                        set: { isOn in
                            if isOn {
                                notificationChannels.insert(channel)
                            } else {
                                notificationChannels.remove(channel)
                            }
                        }
                    ))
                }
            }

            Section {
                HStack {
                    if onCancel != nil {
                        Button("取消", role: .cancel) {
                            onCancel?()
                        }
                    }

                    Spacer()

                    Button(justSaved ? "已保存 ✓" : "保存") {
                        saveRule()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draftRule.isConfigured || justSaved)
                }
            }
        }
        .formStyle(.grouped)
        .radarFrostedBackdrop()
        .padding()
        .onAppear {
            if let rule = rule {
                name = rule.name
                accountHandle = rule.accountHandle
                feedURL = rule.feedURL ?? ""
                isFeedRule = rule.feedURL != nil
                enabled = rule.enabled
                triggerMode = rule.triggerMode
                includeKeywords = rule.includeKeywords
                excludeKeywords = rule.excludeKeywords
                keywordMatchMode = rule.keywordMatchMode
                caseSensitive = rule.caseSensitive
                includeReplies = rule.includeReplies
                includeReposts = rule.includeReposts
                notificationChannels = rule.notificationChannels
            } else {
                name = "新规则"
            }
        }
    }

    /// 当前表单状态对应的规则草稿（保存门槛与内联校验共用同一判据）。
    private var draftRule: MonitorRule {
        MonitorRule(
            id: rule?.id ?? UUID(),
            name: name,
            accountHandle: accountHandle,
            feedURL: isFeedRule ? feedURL : nil,
            enabled: enabled,
            triggerMode: triggerMode,
            includeKeywords: includeKeywords,
            excludeKeywords: excludeKeywords,
            keywordMatchMode: keywordMatchMode,
            caseSensitive: caseSensitive,
            includeReplies: includeReplies,
            includeReposts: includeReposts,
            notificationChannels: notificationChannels,
            createdAt: rule?.createdAt ?? Date(),
            updatedAt: Date()
        )
    }

    private func saveRule() {
        // RSS 源规则：名称缺省时用域名；accountHandle 用作显示名。
        var resolvedName = name
        var resolvedHandle = accountHandle
        let resolvedFeedURL: String?
        if isFeedRule {
            let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedFeedURL = trimmed
            if let host = URL(string: trimmed)?.host {
                if resolvedName.isEmpty { resolvedName = host }
                if resolvedHandle.isEmpty { resolvedHandle = host }
            }
        } else {
            resolvedFeedURL = nil
        }
        let updatedRule = MonitorRule(
            id: rule?.id ?? UUID(),
            name: resolvedName,
            accountHandle: resolvedHandle,
            feedURL: resolvedFeedURL,
            enabled: enabled,
            triggerMode: triggerMode,
            includeKeywords: includeKeywords,
            excludeKeywords: excludeKeywords,
            keywordMatchMode: keywordMatchMode,
            caseSensitive: caseSensitive,
            includeReplies: includeReplies,
            includeReposts: includeReposts,
            notificationChannels: notificationChannels,
            createdAt: rule?.createdAt ?? Date(),
            updatedAt: Date()
        )
        onSave(updatedRule)

        // 保存成功反馈：按钮短暂显示"已保存 ✓"（detail 模式无页面跳转，需要明确确认）。
        justSaved = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justSaved = false
        }
    }
}

struct KeywordTagEditor: View {
    @Binding var keywords: [String]
    @State private var newKeyword: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
                ForEach(keywords, id: \.self) { keyword in
                    KeywordTag(text: keyword) {
                        keywords.removeAll { $0 == keyword }
                    }
                }
            }

            HStack {
                TextField("添加关键词", text: $newKeyword)
                    .onSubmit {
                        addKeyword()
                    }

                Button("添加") {
                    addKeyword()
                }
                .disabled(newKeyword.isEmpty)
            }
        }
    }

    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !keywords.contains(trimmed) else { return }
        keywords.append(trimmed)
        newKeyword = ""
    }
}

struct KeywordTag: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: result.positions[index].x + bounds.minX,
                                      y: result.positions[index].y + bounds.minY),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}
