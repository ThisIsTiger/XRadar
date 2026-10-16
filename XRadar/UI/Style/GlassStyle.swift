// GlassStyle.swift
// 统一的"清新透明"材质风格：
// - macOS 26+ 使用系统 Liquid Glass（glassEffect）
// - 更早版本优雅降级为 ultraThinMaterial 圆角卡片
// 所有自定义材质都从这里取用，保证全局一致并集中管理可用性分支。
import SwiftUI

extension View {
    /// 玻璃圆角卡片背景。
    @ViewBuilder
    func radarGlassCard(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
        }
    }

    /// 玻璃胶囊（徽章、小标签）。
    @ViewBuilder
    func radarGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular)
        } else {
            self.background(.ultraThinMaterial, in: .capsule)
        }
    }

    /// 列表/表单的透明底：隐藏默认不透明白底，露出窗口毛玻璃。
    func radarFrostedBackdrop() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
    }
}
