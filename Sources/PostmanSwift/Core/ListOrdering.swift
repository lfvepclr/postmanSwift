import Foundation

/// Pure reorder helper for drag-and-drop lists (environments, mock services and cases).
enum ListOrdering {
    /// Moves the item at `source` so it lands before `targetIndex` in the original array.
    static func moved<T>(_ items: [T], from source: Int, to targetIndex: Int) -> [T] {
        guard items.indices.contains(source) else { return items }
        var target = max(0, min(targetIndex, items.count))
        if source < target {
            target -= 1
        }
        guard target != source, target >= 0, target < items.count else { return items }
        var copy = items
        let item = copy.remove(at: source)
        copy.insert(item, at: min(target, copy.count))
        return copy
    }
}
