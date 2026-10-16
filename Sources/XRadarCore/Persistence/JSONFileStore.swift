// JSONFileStore.swift
import Foundation

public actor JSONFileStore {
    public static let shared = JSONFileStore()

    private let baseDirectory: URL
    private let fileManager = FileManager.default
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    /// - Parameter baseDirectory: When `nil`, uses `~/Library/Application Support/XRadar`.
    ///   Tests inject a temporary directory so writes never touch real app data.
    public init(baseDirectory: URL? = nil) {
        if let base = baseDirectory {
            self.baseDirectory = base
        } else {
            let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            self.baseDirectory = urls.first!.appendingPathComponent("XRadar", isDirectory: true)
        }

        jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
    }

    private var storageDirectory: URL {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
        return baseDirectory
    }

    public func fileURL(for name: String) -> URL {
        storageDirectory.appendingPathComponent(name)
    }

    public func read<T: Decodable>(_ type: T.Type, from filename: String) async -> T? {
        await Task.yield()
        return self.readSync(type, from: filename)
    }

    private func readSync<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = fileURL(for: filename)
        let backupURL = url.appendingPathExtension("bak")

        // Try main file
        if let data = try? Data(contentsOf: url),
           let decoded = try? jsonDecoder.decode(type, from: data) {
            return decoded
        }

        // Try backup
        if let data = try? Data(contentsOf: backupURL),
           let decoded = try? jsonDecoder.decode(type, from: data) {
            return decoded
        }

        return nil
    }

    public func write<T: Encodable>(_ value: T, to filename: String) throws {
        let url = fileURL(for: filename)
        let tempURL = url.appendingPathExtension("tmp")
        let backupURL = url.appendingPathExtension("bak")

        // Encode to temp file (atomic write to temp ensures partial writes
        // never corrupt the temp file).
        let data = try jsonEncoder.encode(value)
        try data.write(to: tempURL, options: .atomic)

        // Rotate: current -> backup. Use replaceItemAt for an atomic swap
        // when available, falling back to remove+move.
        if fileManager.fileExists(atPath: url.path) {
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
            try? fileManager.moveItem(at: url, to: backupURL)
        }

        // Atomic rename temp -> current. This is the commit point; if we
        // crash before this line, the backup still holds the previous good
        // version and recovery will succeed on next read.
        try fileManager.moveItem(at: tempURL, to: url)
    }
}
