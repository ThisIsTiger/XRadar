// InstanceHealthTracker.swift
// RSSHub 实例健康与冷却（DESIGN-RSSHUB.md §7.2）
import Foundation

/// 在 App 生命周期内保存每个 baseURL 的健康状态，冷却中的实例后续账号直接跳过。
public actor InstanceHealthTracker {
    public struct InstanceState: Sendable, Equatable {
        public var isCooldown: Bool
        public var cooldownUntil: Date?
        public var lastError: String?
        public var lastSuccessAt: Date?
        public var requestCount: Int

        public init(
            isCooldown: Bool = false,
            cooldownUntil: Date? = nil,
            lastError: String? = nil,
            lastSuccessAt: Date? = nil,
            requestCount: Int = 0
        ) {
            self.isCooldown = isCooldown
            self.cooldownUntil = cooldownUntil
            self.lastError = lastError
            self.lastSuccessAt = lastSuccessAt
            self.requestCount = requestCount
        }
    }

    public enum CooldownCause: Sendable {
        case rateLimited(retryAfter: Date?)
        case serverError
        case network
        case invalidFeed
        case suspiciousEmpty
        case emptyUnverified
    }

    private var states: [String: InstanceState] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// 返回可用的实例（未冷却且未超过冷却期），按优先级排序。
    /// 优先上次成功实例，再按给定顺序。
    public func usableInstances(_ order: [String]) -> [String] {
        let current = now()
        var available = order.filter { instance in
            guard let state = states[instance] else { return true }
            if state.isCooldown, let until = state.cooldownUntil, until > current {
                return false
            }
            return true
        }
        available.sort { lhs, rhs in
            let lhsSuccess = states[lhs]?.lastSuccessAt
            let rhsSuccess = states[rhs]?.lastSuccessAt
            switch (lhsSuccess, rhsSuccess) {
            case (.some, .none): return true
            case (.none, .some): return false
            case (.some(let l), .some(let r)): return l > r
            case (.none, .none): return false
            }
        }
        return available
    }

    public func recordSuccess(_ instance: String) {
        let current = now()
        states[instance] = InstanceState(
            isCooldown: false,
            cooldownUntil: nil,
            lastError: nil,
            lastSuccessAt: current,
            requestCount: (states[instance]?.requestCount ?? 0) + 1
        )
    }

    public func recordFailure(_ instance: String, cause: CooldownCause, error: String?) {
        let current = now()
        let duration: TimeInterval
        switch cause {
        case .rateLimited(let retryAfter):
            duration = (retryAfter?.timeIntervalSince(current) ?? 0) > 0
                ? retryAfter!.timeIntervalSince(current)
                : 15 * 60
        case .serverError, .network:
            duration = 2 * 60
        case .invalidFeed, .suspiciousEmpty, .emptyUnverified:
            duration = 5 * 60
        }
        states[instance] = InstanceState(
            isCooldown: true,
            cooldownUntil: current.addingTimeInterval(duration),
            lastError: error,
            lastSuccessAt: states[instance]?.lastSuccessAt,
            requestCount: (states[instance]?.requestCount ?? 0) + 1
        )
    }

    public func state(of instance: String) -> InstanceState? {
        states[instance]
    }

    /// 全部实例是否都在冷却中（用于 Router 判断整轮失败）。
    public func allInCooldown(_ instances: [String]) -> Bool {
        guard !instances.isEmpty else { return true }
        return usableInstances(instances).isEmpty
    }

    public func reset() {
        states.removeAll()
    }
}