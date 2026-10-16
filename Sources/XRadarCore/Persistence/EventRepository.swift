// EventRepository.swift
import Foundation
import os.log

@MainActor
public class EventRepository: ObservableObject {
    private let filename = "events.json"
    private let store: JSONFileStore
    private var maxEvents: Int
    private var retentionDays: Int
    private static let logger = Logger(subsystem: "com.xradar.app", category: "EventRepository")

    public init(store: JSONFileStore = .shared, maxEvents: Int = 500, retentionDays: Int = 30) {
        self.store = store
        self.maxEvents = maxEvents
        self.retentionDays = retentionDays
    }

    public func updatePolicy(maxEvents: Int, retentionDays: Int) {
        self.maxEvents = max(1, maxEvents)
        self.retentionDays = max(1, retentionDays)
    }

    public func loadEvents() async -> [NotificationEvent] {
        if let wrapper = await store.read(EventsWrapper.self, from: filename) {
            return wrapper.events
        }
        return []
    }

    public func saveEvents(_ events: [NotificationEvent]) async {
        let wrapper = EventsWrapper(schemaVersion: 1, events: events)
        do {
            try await store.write(wrapper, to: filename)
        } catch {
            Self.logger.error("Failed to save events: \(error.localizedDescription)")
        }
    }

    public func appendEvent(_ event: NotificationEvent) async {
        var events = await loadEvents()
        events.append(event)
        events = pruneEvents(events)
        await saveEvents(events)
    }

    /// Batch-append multiple events with a single load/save cycle.
    public func appendEvents(_ newEvents: [NotificationEvent]) async {
        guard !newEvents.isEmpty else { return }
        var events = await loadEvents()
        events.append(contentsOf: newEvents)
        events = pruneEvents(events)
        await saveEvents(events)
    }

    public func deleteEvent(_ event: NotificationEvent) async {
        var events = await loadEvents()
        events.removeAll { $0.id == event.id }
        await saveEvents(events)
    }

    public func clearAllEvents() async {
        await saveEvents([])
    }

    /// Remove events older than retentionDays and cap total at maxEvents.
    private func pruneEvents(_ events: [NotificationEvent]) -> [NotificationEvent] {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        var pruned = events.filter { $0.createdAt >= cutoff }

        // Keep most recent maxEvents
        if pruned.count > maxEvents {
            pruned = Array(pruned.suffix(maxEvents))
        }
        return pruned
    }
}

struct EventsWrapper: Codable {
    let schemaVersion: Int
    var events: [NotificationEvent]
}
