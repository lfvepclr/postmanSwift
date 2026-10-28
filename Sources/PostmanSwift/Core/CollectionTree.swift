import Foundation

struct InheritedScripts: Hashable {
    var preRequest: [String] = []
    var tests: [String] = []
}

struct RequestReference: Identifiable, Hashable {
    var id: String { item.id }
    var collectionID: String
    var collectionName: String
    var item: CollectionItem
    var folderPath: [String]
    var effectiveAuth: Auth
    var inheritedScripts = InheritedScripts()
}

enum CollectionTree {
    static func find(_ items: [CollectionItem], id: String) -> CollectionItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.item, let found = find(children, id: id) { return found }
        }
        return nil
    }

    static func path(to id: String, in items: [CollectionItem], prefix: [CollectionItem] = []) -> [CollectionItem]? {
        for item in items {
            if item.id == id { return prefix + [item] }
            if let children = item.item, let found = path(to: id, in: children, prefix: prefix + [item]) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    static func update(_ items: inout [CollectionItem], id: String, transform: (inout CollectionItem) -> Void) -> Bool {
        for index in items.indices {
            if items[index].id == id {
                transform(&items[index])
                return true
            }
            if var children = items[index].item {
                if update(&children, id: id, transform: transform) {
                    items[index].item = children
                    return true
                }
            }
        }
        return false
    }

    @discardableResult
    static func remove(_ items: inout [CollectionItem], id: String) -> CollectionItem? {
        for index in items.indices {
            if items[index].id == id {
                return items.remove(at: index)
            }
            if var children = items[index].item {
                if let removed = remove(&children, id: id) {
                    items[index].item = children.isEmpty ? nil : children
                    return removed
                }
            }
        }
        return nil
    }

    static func insert(_ newItem: CollectionItem, into items: inout [CollectionItem], parentID: String?) {
        guard let parentID else {
            items.append(newItem)
            return
        }
        if update(&items, id: parentID, transform: { parent in
            var children = parent.item ?? []
            children.append(newItem)
            parent.item = children
        }) {
            return
        }
        items.append(newItem)
    }

    /// Moves `itemID` under `toParentID` (nil = collection root), placing it before
    /// `beforeSiblingID` or appending when that sibling is nil. Rejects moves into the
    /// item itself or one of its descendants, which would detach the subtree.
    @discardableResult
    static func move(
        _ items: inout [CollectionItem],
        itemID: String,
        toParentID: String?,
        beforeSiblingID: String?
    ) -> Bool {
        guard let path = path(to: itemID, in: items) else { return false }
        let currentParentID = path.count > 1 ? path[path.count - 2].id : nil
        if beforeSiblingID == itemID { return false }
        if let toParentID {
            guard toParentID != itemID,
                  let parent = find(items, id: toParentID),
                  parent.isFolder,
                  let moving = find(items, id: itemID),
                  find(moving.item ?? [], id: toParentID) == nil else { return false }
        }
        if currentParentID == toParentID, beforeSiblingID == nil,
           (children(of: toParentID, in: items) ?? []).last?.id == itemID {
            return false
        }
        guard let moved = remove(&items, id: itemID) else { return false }
        insert(moved, before: beforeSiblingID, into: &items, parentID: toParentID)
        return true
    }

    /// Ids of the item and everything nested beneath it. Used as the set of drop parents
    /// that must be rejected while dragging that item.
    static func subtreeIDs(_ item: CollectionItem) -> Set<String> {
        var ids: Set<String> = [item.id]
        for child in item.item ?? [] {
            ids.formUnion(subtreeIDs(child))
        }
        return ids
    }

    static func children(of parentID: String?, in items: [CollectionItem]) -> [CollectionItem]? {
        guard let parentID else { return items }
        return find(items, id: parentID)?.item
    }

    private static func insert(
        _ item: CollectionItem,
        before siblingID: String?,
        into items: inout [CollectionItem],
        parentID: String?
    ) {
        func place(in array: inout [CollectionItem]) {
            if let siblingID, let index = array.firstIndex(where: { $0.id == siblingID }) {
                array.insert(item, at: index)
            } else {
                array.append(item)
            }
        }
        guard let parentID else {
            place(in: &items)
            return
        }
        var placed = false
        update(&items, id: parentID) { parent in
            var children = parent.item ?? []
            place(in: &children)
            parent.item = children
            placed = true
        }
        if !placed { place(in: &items) }
    }

    static func flatten(_ collection: PMCollection) -> [RequestReference] {
        var result: [RequestReference] = []
        func walk(_ items: [CollectionItem], path: [String]) {
            for item in items {
                if item.isFolder {
                    walk(item.item ?? [], path: path + [item.name])
                } else if item.request != nil {
                    result.append(RequestReference(
                        collectionID: collection.id,
                        collectionName: collection.info.name,
                        item: item,
                        folderPath: path,
                        effectiveAuth: effectiveAuth(collection: collection, itemID: item.id),
                        inheritedScripts: scripts(collection: collection, itemID: item.id)
                    ))
                }
            }
        }
        walk(collection.items, path: [])
        return result
    }

    static func effectiveAuth(collection: PMCollection, itemID: String) -> Auth {
        guard let chain = path(to: itemID, in: collection.items) else {
            return collection.auth ?? .none
        }
        for node in chain.reversed() {
            if let requestAuth = node.request?.auth, !requestAuth.isInherit { return requestAuth }
            if let auth = node.auth, !auth.isInherit { return auth }
        }
        if let auth = collection.auth, !auth.isInherit { return auth }
        return .none
    }

    static func folderAuth(collection: PMCollection, folderID: String) -> Auth {
        guard let chain = path(to: folderID, in: collection.items) else { return .none }
        for node in chain.reversed() {
            if let requestAuth = node.request?.auth, !requestAuth.isInherit { return requestAuth }
            if let auth = node.auth, !auth.isInherit { return auth }
        }
        return collection.auth ?? .none
    }

    /// Pre-request scripts run outer-to-inner; tests run inner-to-outer, matching collection inheritance.
    static func scripts(collection: PMCollection, itemID: String) -> InheritedScripts {
        var result = InheritedScripts()
        let collectionPre = collection.preRequestScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !collectionPre.isEmpty { result.preRequest.append(collection.preRequestScript) }
        let collectionTest = collection.testScript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let chain = path(to: itemID, in: collection.items) else { return result }
        let folders = chain.dropLast().filter(\.isFolder)
        for folder in folders {
            let script = folder.preRequestScript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !script.isEmpty { result.preRequest.append(folder.preRequestScript) }
        }
        for folder in folders.reversed() {
            let script = folder.testScript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !script.isEmpty { result.tests.append(folder.testScript) }
        }
        if !collectionTest.isEmpty { result.tests.append(collection.testScript) }
        return result
    }

    static func newRequestItem(named name: String = "Untitled Request") -> CollectionItem {
        var item = CollectionItem(name: name, request: RequestDef(method: "GET", url: ""))
        item.request?.url = URLDef(raw: "")
        return item
    }

    static func newFolderItem(named name: String = "New Folder") -> CollectionItem {
        CollectionItem(name: name, request: nil, item: [])
    }

    static func allItems(_ collection: PMCollection) -> [CollectionItem] {
        var result: [CollectionItem] = []
        func walk(_ items: [CollectionItem]) {
            for item in items {
                result.append(item)
                if let children = item.item { walk(children) }
            }
        }
        walk(collection.items)
        return result
    }
}
