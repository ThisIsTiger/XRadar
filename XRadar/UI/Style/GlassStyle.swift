// GlassStyle.swift
// 统一的"清新透明"材质风格：
// - 使用 Xcode 26+（Swift 6.2+ / macOS 26 SDK）时，运行时若为 macOS 26+ 则用系统
//   Liquid Glass（glassEffect）
// - 其余情况（旧工具链或旧系统）优雅降级为 ultraThinMaterial 圆角卡片
// 编译期用 `#if compiler(>=6.2)` 门控：`glassEffect` 的符号只存在于 macOS 26 SDK，
// 因此必须在 SDK 层面排除，而不能只靠 `#available`（否则旧 SDK 直接编译失败）。
import SwiftUI

extension View {
    /// 玻璃圆角卡片背景。
    @ViewBuilder
    func radarGlassCard(cornerRadius: CGFloat = 14) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.radarMaterialCard(cornerRadius: cornerRadius)
        }
        #else
        self.radarMaterialCard(cornerRadius: cornerRadius)
        #endif
    }

    /// 玻璃胶囊（徽章、小标签）。
    @ViewBuilder
    func radarGlassCapsule() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular)
        } else {
            self.radarMaterialCapsule()
        }
        #else
        self.radarMaterialCapsule()
        #endif
    }

    /// 列表/表单的透明底：隐藏默认不透明白底，露出窗口毛玻璃。
    func radarFrostedBackdrop() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
    }
}

private extension View {
    func radarMaterialCard(cornerRadius: CGFloat) -> some View {
        self
            .background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }

    func radarMaterialCapsule() -> some View {
        self.background(.ultraThinMaterial, in: .capsule)
    }
}
