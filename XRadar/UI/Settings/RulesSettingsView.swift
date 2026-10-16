// RulesSettingsView.swift
import SwiftUI
import XRadarCore

struct RulesSettingsView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var selectedRule: MonitorRule?
    @State private var showingAddRule = false
    /// 待确认删除的规则（onDelete 先进入确认流程，防止误触直接丢失配置）。
    @State private var pendingDeleteRules: [MonitorRule] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedRule) {
                ForEach(appModel.configuration.rules) { rule in
                    RuleRow(rule: rule)
                        .tag(rule)
                }
                .onDelete { indexSet in
                    pendingDeleteRules = indexSet.map { appModel.configuration.rules[$0] }
                }
            }
            .toolbar {
                ToolbarItem {
                    Button(action: { showingAddRule = true }) {
                        Label("添加规则", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddRule) {
                RuleEditorView(rule: nil, onCancel: { showingAddRule = false }) { newRule in
                    appModel.addRule(newRule)
                    showingAddRule = false
                }
            }
            .confirmationDialog(
                "删除 \(pendingDeleteRules.count) 条规则？",
                isPresented: Binding(
                    get: { !pendingDeleteRules.isEmpty },
                    set: { if !$0 { pendingDeleteRules = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    for rule in pendingDeleteRules {
                        appModel.deleteRule(rule)
                    }
                    if pendingDeleteRules.contains(where: { $0.id == selectedRule?.id }) {
                        selectedRule = nil
                    }
                    pendingDeleteRules = []
                }
                Button("取消", role: .cancel) {
                    pendingDeleteRules = []
                }
            } message: {
                Text("规则的关键词与通知配置将被移除，此操作不可撤销。")
            }
        } detail: {
            if let rule = selectedRule {
                RuleEditorView(rule: rule) { updatedRule in
                    appModel.updateRule(updatedRule)
                }
                .id(rule.id)
            } else {
                Text("选择一个规则或创建新规则")
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct RuleRow: View {
    let rule: MonitorRule

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.name)
                    .fontWeight(.medium)
                Spacer()
                StatusIndicator(enabled: rule.enabled)
            }

            if let feedURL = rule.feedURL, let host = URL(string: feedURL)?.host {
                Text("RSS 源 · \(host)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("@\(rule.accountHandle)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text(rule.triggerMode.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())

                if !rule.includeKeywords.isEmpty {
                    Text("\(rule.includeKeywords.count) 个关键词")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusIndicator: View {
    let enabled: Bool

    var body: some View {
        Circle()
            .fill(enabled ? Color.green : Color.red)
            .frame(width: 8, height: 8)
    }
}
