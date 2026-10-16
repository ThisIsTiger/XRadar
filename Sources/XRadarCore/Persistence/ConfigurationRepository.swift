// ConfigurationRepository.swift
import Foundation
import os.log

@MainActor
public class ConfigurationRepository: ObservableObject {
    private let filename = "config.json"
    private let store: JSONFileStore
    private static let logger = Logger(subsystem: "com.xradar.app", category: "ConfigurationRepository")

    public init(store: JSONFileStore = .shared) {
        self.store = store
    }

    public func load() async -> AppConfiguration {
        if let config = await store.read(AppConfiguration.self, from: filename) {
            // v1 → v2 迁移落盘（DESIGN-RSSHUB.md §4.2 第 5 条）
            if config.schemaVersion < 2 {
                var migrated = config
                migrated.schemaVersion = 2
                await save(migrated)
                return migrated
            }
            return config
        }
        return .default
    }

    public func save(_ configuration: AppConfiguration) async {
        do {
            try await store.write(configuration, to: filename)
        } catch {
            Self.logger.error("Failed to save configuration: \(error.localizedDescription)")
        }
    }
}
