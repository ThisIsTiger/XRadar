// PollingSettingsView.swift
import SwiftUI
import XRadarCore

struct PollingSettingsView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        Form {
            Section("检查频率") {
                Picker("检查频率", selection: Binding(
                    get: { appModel.configuration.pollInterval },
                    set: { appModel.updatePollingInterval($0) }
                )) {
                    ForEach(PollingInterval.allCases, id: \.self) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("行为") {
                Toggle("启动应用时立即检查", isOn: Binding(
                    get: { appModel.configuration.runCheckAtLaunch },
                    set: { appModel.setRunCheckAtLaunch($0) }
                ))

                Toggle("Mac 唤醒后立即检查", isOn: Binding(
                    get: { appModel.configuration.runCheckAfterWake },
                    set: { appModel.setRunCheckAfterWake($0) }
                ))
            }

            Section("状态") {
                HStack {
                    Text("上次检查")
                    Spacer()
                    Text(lastCheckText)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("下次检查")
                    Spacer()
                    Text(nextCheckText)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Button("立即检查") {
                        appModel.triggerNow()
                    }
                    .disabled(isChecking || manualCheckBlockedReason != nil)

                    if let reason = manualCheckBlockedReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .radarFrostedBackdrop()
        .padding()
    }

    private var isChecking: Bool {
        if case .running = appModel.runtimeState.status { return true }
        return false
    }

    private var manualCheckBlockedReason: String? {
        appModel.runtimeState.status.manualCheckBlockedReason
    }

    private var lastCheckText: String {
        if let lastRunAt = appModel.runtimeState.lastRunAt {
            return lastRunAt.formatted(.dateTime.month().day().hour().minute().second())
        }
        return "尚未检查"
    }

    private var nextCheckText: String {
        if appModel.runtimeState.isPaused {
            return "已暂停"
        }
        // 退避中的真实调度时间（§8.3），比按间隔估算更准确。
        if let backoff = appModel.runtimeState.backoffUntil, backoff > Date() {
            return "退避至 \(backoff.formatted(.dateTime.hour().minute().second()))"
        }
        if let lastRunAt = appModel.runtimeState.lastRunAt {
            let nextDate = lastRunAt.addingTimeInterval(TimeInterval(appModel.configuration.pollInterval.rawValue))
            if nextDate > Date() {
                return nextDate.formatted(.dateTime.month().day().hour().minute().second())
            } else {
                return "即将检查"
            }
        }
        return "即将检查"
    }
}
