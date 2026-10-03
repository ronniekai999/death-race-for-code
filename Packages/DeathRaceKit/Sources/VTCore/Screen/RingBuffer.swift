/// A growable ring buffer: O(1) append at the end and removal from the front, which is all
/// scrollback needs (lines arrive at the bottom, the budget trims the top).
struct RingBuffer<Element> {
    private var storage: ContiguousArray<Element?>
    private var head = 0
    private(set) var count = 0

    init(capacity: Int = 64) {
        storage = ContiguousArray(repeating: nil, count: max(capacity, 1))
    }

    var isEmpty: Bool { count == 0 }

    subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count, "RingBuffer index out of range")
            return storage[(head + index) % storage.count]!
        }
        set {
            precondition(index >= 0 && index < count, "RingBuffer index out of range")
            storage[(head + index) % storage.count] = newValue
        }
    }

    var first: Element? { count > 0 ? self[0] : nil }
    var last: Element? { count > 0 ? self[count - 1] : nil }

    mutating func append(_ element: Element) {
        if count == storage.count { grow() }
        storage[(head + count) % storage.count] = element
        count += 1
    }

    @discardableResult
    mutating func removeFirst() -> Element {
        precondition(count > 0, "RingBuffer is empty")
        let element = storage[head]!
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return element
    }

    @discardableResult
    mutating func removeLast() -> Element {
        precondition(count > 0, "RingBuffer is empty")
        let index = (head + count - 1) % storage.count
        let element = storage[index]!
        storage[index] = nil
        count -= 1
        return element
    }

    mutating func removeAll() {
        storage = ContiguousArray(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }

    private mutating func grow() {
        var bigger = ContiguousArray<Element?>(repeating: nil, count: storage.count * 2)
        for index in 0..<count { bigger[index] = storage[(head + index) % storage.count] }
        storage = bigger
        head = 0
    }
}
