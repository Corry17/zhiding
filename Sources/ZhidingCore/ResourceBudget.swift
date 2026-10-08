import Foundation

public enum PinKind: String, Sendable { case screenshot, mirror }

public actor ResourceBudget {
    public struct Snapshot: Sendable {
        public let bytes: Int
        public let pins: Int
        public let mirrors: Int
    }
    private struct Entry { let kind: PinKind?; var bytes: Int }
    private var entries: [UUID: Entry] = [:]
    public init() {}

    public func reserve(bytes: Int, kind: PinKind? = nil) throws -> UUID {
        let current = snapshot()
        if kind == .screenshot, current.pins >= Limits.pins { throw ZhidingError.pinLimit }
        if kind == .mirror, current.mirrors >= Limits.mirrors { throw ZhidingError.mirrorLimit }
        guard bytes >= 0, bytes <= Limits.memoryBytes - current.bytes else { throw ZhidingError.budgetExceeded }
        let id = UUID()
        entries[id] = Entry(kind: kind, bytes: bytes)
        return id
    }

    public func resize(_ id: UUID, bytes: Int) throws {
        guard let old = entries[id] else { throw ZhidingError.cancelled }
        guard bytes >= 0, bytes <= Limits.memoryBytes - (snapshot().bytes - old.bytes) else {
            throw ZhidingError.budgetExceeded
        }
        entries[id]?.bytes = bytes
    }

    public func release(_ id: UUID) { entries.removeValue(forKey: id) }

    public func snapshot() -> Snapshot {
        Snapshot(bytes: entries.values.reduce(0) { $0 + $1.bytes },
                 pins: entries.values.filter { $0.kind == .screenshot }.count,
                 mirrors: entries.values.filter { $0.kind == .mirror }.count)
    }
}

// 同步锁只保护单个最新值；通知消费期间不会无界累积主线程任务。
public final class LatestMailbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var notificationPending = false
    private var accepting = true
    public init() {}

    public func offer(_ newValue: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }
        value = newValue
        guard !notificationPending else { return false }
        notificationPending = true
        return true
    }

    public func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        let result = value
        value = nil
        notificationPending = false
        return result
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        value = nil
        notificationPending = false
    }
}

public struct OperationGate: Sendable {
    public private(set) var generation = UUID()
    public private(set) var protected = false
    public init() {}
    public mutating func invalidate() { generation = UUID() }
    public mutating func protect() { protected = true; invalidate() }
    public mutating func resume() { protected = false; invalidate() }
    public func accepts(_ token: UUID) -> Bool { !protected && generation == token }
}
