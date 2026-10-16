// XSessionState.swift
import Foundation

public enum XSessionState: Equatable, Sendable {
    case unknown
    case loggedOut
    case validating
    case loggedIn(handle: String?)
    case probablyLoggedIn
    case actionRequired(message: String)
    case failed(message: String)

    public var isLoggedIn: Bool {
        switch self {
        case .loggedIn, .probablyLoggedIn:
            return true
        default:
            return false
        }
    }

    /// True when we cannot confidently say the session is logged in. Drives the
    /// "login required" status used by the monitoring pipeline.
    public var isPossiblyLoggedIn: Bool {
        switch self {
        case .loggedIn, .probablyLoggedIn:
            return true
        default:
            return false
        }
    }

    public var actionRequiredMessage: String? {
        if case .actionRequired(let message) = self {
            return message
        }
        return nil
    }

    public var notLoggedInReason: String? {
        switch self {
        case .loggedOut:
            return "X 登录已失效，请重新登录"
        case .actionRequired(let message):
            return "需要处理: \(message)"
        case .failed(let message):
            return "登录验证失败: \(message)"
        case .validating, .unknown:
            return "登录状态未知"
        default:
            return nil
        }
    }

    public var displayText: String {
        switch self {
        case .unknown:
            return "未知"
        case .loggedOut:
            return "未登录"
        case .validating:
            return "验证中..."
        case .loggedIn(let handle):
            return handle.map { "@\($0)" } ?? "已登录"
        case .probablyLoggedIn:
            return "可能已登录"
        case .actionRequired(let message):
            return "需要操作: \(message)"
        case .failed(let message):
            return "失败: \(message)"
        }
    }
}
