// SettingsView.swift
import SwiftUI
import XRadarCore

struct SettingsView: View {
    @EnvironmentObject var appModel: AppModel
    /// 全局共享（AppStorage）：菜单栏状态区点击后写入此键，所有已打开的
    /// 设置窗口同步切换到目标 tab。
    @AppStorage("settings.selectedTab") private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            SourceSettingsView()
                .tabItem {
                    Label("信源", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(0)

            AccountSettingsView()
                .tabItem {
                    Label("X 账号", systemImage: "person")
                }
                .tag(1)

            RulesSettingsView()
                .tabItem {
                    Label("监控规则", systemImage: "list.bullet")
                }
                .tag(2)

            PollingSettingsView()
                .tabItem {
                    Label("抓取配置", systemImage: "arrow.clockwise")
                }
                .tag(3)

            FetchHistoryView()
                .tabItem {
                    Label("抓取历史", systemImage: "clock.arrow.circlepath")
                }
                .tag(4)

            NotificationsSettingsView()
                .tabItem {
                    Label("通知", systemImage: "bell")
                }
                .tag(5)

            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
                .tag(6)
        }
        .frame(minWidth: 800, minHeight: 560)
        .environmentObject(appModel)
    }
}
