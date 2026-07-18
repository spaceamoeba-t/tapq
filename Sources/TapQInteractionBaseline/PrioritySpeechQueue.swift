import Foundation
import TapQContracts

/// A queued utterance independent of any speech-synthesis framework.
public struct SpeechQueueItem {
    public let id: UUID
    public let text: String
    public let priority: SpeechPriority
    public let onFinish: (() -> Void)?

    public init(id: UUID = UUID(), text: String, priority: SpeechPriority,
                onFinish: (() -> Void)? = nil) {
        self.id = id
        self.text = text
        self.priority = priority
        self.onFinish = onFinish
    }
}

/// Portable priority and lifecycle policy used by platform speech synthesizers.
/// Equal-priority items remain FIFO; a higher-priority enqueue asks the adapter to
/// cancel the current utterance so the new item can run next.
public struct PrioritySpeechQueue {
    private var pending: [SpeechQueueItem] = []
    public private(set) var current: SpeechQueueItem?

    public init() {}

    public var isBusy: Bool { current != nil || !pending.isEmpty }
    public var pendingCount: Int { pending.count }

    @discardableResult
    public mutating func enqueue(_ item: SpeechQueueItem) -> Bool {
        pending.append(item)
        return current.map { item.priority > $0.priority } ?? false
    }

    public mutating func startNext() -> SpeechQueueItem? {
        guard current == nil,
              let maxPriority = pending.map(\.priority).max(),
              let index = pending.firstIndex(where: { $0.priority == maxPriority }) else {
            return nil
        }
        let item = pending.remove(at: index)
        current = item
        return item
    }

    @discardableResult
    public mutating func completeCurrent(id: UUID) -> SpeechQueueItem? {
        guard current?.id == id else { return nil }
        defer { current = nil }
        return current
    }

    public mutating func removeAllPending() -> [SpeechQueueItem] {
        defer { pending.removeAll() }
        return pending
    }
}
