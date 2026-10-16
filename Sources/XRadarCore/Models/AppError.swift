// AppError.swift
import Foundation

public enum AppError: Error, Equatable, Sendable {
    case invalidHandle
    case authenticationRequired
    case userActionRequired(String)
    case rateLimited(Date?)
    case pageLoadTimeout
    case pageStructureChanged
    case networkUnavailable
    case persistenceFailure(String)
    case notificationPermissionDenied
    case telegramConfigurationInvalid
    case telegramRequestFailed(statusCode: Int)

    public var userMessage: String {
        switch self {
        case .invalidHandle:
            return "无效的账号格式"
        case .authenticationRequired:
            return "X 登录已失效，请重新登录"
        case .userActionRequired(let message):
            return "需要处理: \(message)"
        case .rateLimited:
            return "请求过于频繁，请稍后再试"
        case .pageLoadTimeout:
            return "页面加载超时"
        case .pageStructureChanged:
            return "X 页面结构可能已变化"
        case .networkUnavailable:
            return "网络不可用"
        case .persistenceFailure:
            return "数据保存失败"
        case .notificationPermissionDenied:
            return "通知权限被拒绝"
        case .telegramConfigurationInvalid:
            return "Telegram 配置无效"
        case .telegramRequestFailed:
            return "Telegram 发送失败"
        }
    }
}
