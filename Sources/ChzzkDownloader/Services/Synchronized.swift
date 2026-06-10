import Foundation

/// Tiny synchronous state container for callbacks and nonisolated service objects.
/// It keeps shared state behind short, deterministic serial critical sections.
final class Synchronized<Value> {
    private let queue: DispatchQueue
    private var value: Value

    init(_ value: Value, label: String) {
        self.value = value
        self.queue = DispatchQueue(label: label)
    }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try queue.sync { try body(&value) }
    }

    func update(_ body: (inout Value) throws -> Void) rethrows {
        try queue.sync { try body(&value) }
    }
}
