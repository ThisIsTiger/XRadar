import Foundation

@MainActor
public final class FetchHistoryRepository {
    private let filename = "fetch-history.json"
    private let store: JSONFileStore
    private var maxRecords: Int

    public init(store: JSONFileStore = .shared, maxRecords: Int = 1_000) {
        self.store = store
        self.maxRecords = max(1, maxRecords)
    }

    public func loadRecords() async -> [FetchRecord] {
        guard let wrapper = await self.store.read(FetchHistoryWrapper.self, from: self.filename) else {
            return []
        }
        guard wrapper.schemaVersion >= 2 else {
            // Version 1 could incorrectly attribute conversation participants'
            // tweets to the monitored account. Do not surface polluted data.
            return []
        }
        let records = self.prunedToValidityWindow(
            self.deduplicated(wrapper.records)
        )
        if records.count != wrapper.records.count || wrapper.schemaVersion != 4 {
            await self.saveRecords(records)
        }
        return records
    }

    public func appendRecords(_ newRecords: [FetchRecord]) async {
        guard !newRecords.isEmpty else { return }
        var records = await self.loadRecords()
        records.insert(contentsOf: newRecords, at: 0)
        records = self.deduplicated(records)
        await self.saveRecords(records)
    }

    public func clear() async {
        await self.saveRecords([])
    }

    public func updateLimit(_ maxRecords: Int) {
        self.maxRecords = max(1, maxRecords)
    }

    private func saveRecords(_ records: [FetchRecord]) async {
        let wrapper = FetchHistoryWrapper(schemaVersion: 4, records: records)
        try? await self.store.write(wrapper, to: self.filename)
    }

    private func deduplicated(_ records: [FetchRecord]) -> [FetchRecord] {
        var uniqueTweets: [String: FetchRecord] = [:]
        var uniqueFailures: [String: FetchRecord] = [:]

        for record in records.sorted(by: { $0.fetchedAt > $1.fetchedAt }) {
            guard let tweetID = record.tweetID else {
                // Repeated polling failures used to flood diagnostics. Preserve
                // the newest occurrence of each account/error combination.
                let key = "\(record.accountHandle.lowercased()):\(record.text)"
                if uniqueFailures[key] == nil {
                    uniqueFailures[key] = record
                }
                continue
            }
            let key = "\(record.accountHandle.lowercased()):\(tweetID)"
            if let existing = uniqueTweets[key] {
                if existing.outcome == .previouslySeen, record.outcome != .previouslySeen {
                    uniqueTweets[key] = record
                }
            } else {
                uniqueTweets[key] = record
            }
        }

        let combined = Array(uniqueTweets.values) + Array(uniqueFailures.values)
        return Array(
            combined
                .sorted { $0.fetchedAt > $1.fetchedAt }
                .prefix(self.maxRecords)
        )
    }

    private func prunedToValidityWindow(_ records: [FetchRecord]) -> [FetchRecord] {
        let earliestPublishedAt = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        return records.filter { record in
            // Fetch failures describe the health of the polling system rather
            // than a tweet, so retain their newest deduplicated occurrence.
            guard record.tweetID != nil else { return true }
            let dateToCheck = record.publishedAt ?? record.fetchedAt
            return dateToCheck >= earliestPublishedAt
        }
    }
}

private struct FetchHistoryWrapper: Codable {
    let schemaVersion: Int
    let records: [FetchRecord]
}
