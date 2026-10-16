// StateRepository.swift
import Foundation
import os.log

@MainActor
public class StateRepository: ObservableObject {
    private let filename = "state.json"
    private let store: JSONFileStore
    private static let logger = Logger(subsystem: "com.xradar.app", category: "StateRepository")

    public init(store: JSONFileStore = .shared) {
        self.store = store
    }

    public func load() async -> RuntimeState {
        if let state = await store.read(RuntimeState.self, from: filename) {
            return state
        }
        return .default
    }

    public func save(_ state: RuntimeState) async {
        do {
            try await store.write(state, to: filename)
        } catch {
            Self.logger.error("Failed to save runtime state: \(error.localizedDescription)")
        }
    }

    public func loadAccountCursor(for handle: String) async -> AccountCursor {
        let state = await load()
        return state.accounts[handle] ?? .empty
    }

    public func saveAccountCursor(_ cursor: AccountCursor, for handle: String) async {
        var state = await load()
        state.accounts[handle] = cursor
        await save(state)
    }
}
