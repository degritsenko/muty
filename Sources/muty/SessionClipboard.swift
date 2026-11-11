import Foundation

enum FolderPaths {
    static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func moved(_ path: String, using mapping: [String: String]) -> String? {
        guard let root = mapping.keys.filter({ contains(path, in: $0) }).max(by: { $0.count < $1.count }),
              let destination = mapping[root] else { return nil }
        return destination + path.dropFirst(root.count)
    }

    static func moveAssignments<Value>(_ assignments: [String: Value], using mapping: [String: String]) -> [String: Value] {
        var result = assignments
        var moves: [(String, Value)] = []
        for path in assignments.keys.sorted() {
            guard let target = moved(path, using: mapping), let value = assignments[path] else { continue }
            result.removeValue(forKey: path)
            moves.append((target, value))
        }
        for (target, value) in moves { result[target] = value }
        return result
    }
}

struct SessionClipboard {
    let profiles: [SessionProfile]
    let roots: [String]
    let folders: [String]
    let cut: Bool
    struct Plan {
        var profiles: [SessionProfile]
        var folders: [String]
        var added: [(source: UUID, copy: SessionProfile)]
        var movedFolders: [String: String]
    }
    func plan(profiles current: [SessionProfile], folders currentFolders: [String], destination: String?) throws -> Plan {
        if let destination, roots.contains(where: { destination == $0 || destination.hasPrefix($0 + "/") }) {
            throw MutyError("A folder cannot be pasted into itself or its subfolders.")
        }
        let sourceIDs = Set(profiles.map(\.id))
        if cut {
            guard sourceIDs.isSubset(of: Set(current.map(\.id))), roots.allSatisfy(currentFolders.contains) else {
                throw MutyError("Some cut items no longer exist. Select them again.")
            }
        }
        // A cut uses current settings and includes newly created descendants.
        let sources = cut ? current.filter { sourceIDs.contains($0.id) || contained($0.folder) } : profiles
        let sourceFolders = cut ? currentFolders.filter { contained($0) } : folders
        var result = cut ? current.filter { !sources.map(\.id).contains($0.id) } : current
        var names = Set(cut ? currentFolders.filter { !contained($0) } : currentFolders)
        var mappedRoots: [String: String] = [:]
        func joined(_ parent: String?, _ name: String) -> String { parent.map { $0 + "/" + name } ?? name }
        for root in roots {
            let base = (root as NSString).lastPathComponent
            var target = joined(destination, base), suffix = 1
            while names.contains(where: { $0.localizedCaseInsensitiveCompare(target) == .orderedSame }) {
                target = joined(destination, base + (suffix == 1 ? " Copy" : " Copy \(suffix)")); suffix += 1
            }
            mappedRoots[root] = target; names.insert(target)
        }
        func mapped(_ folder: String?) -> String? {
            folder.flatMap { FolderPaths.moved($0, using: mappedRoots) } ?? destination
        }
        for folder in sourceFolders { if let value = mapped(folder) { names.insert(value) } }
        let ids = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, cut ? $0.id : UUID()) })
        var added: [(source: UUID, copy: SessionProfile)] = []
        for source in sources {
            var copy = source; copy.id = ids[source.id]!; copy.folder = mapped(source.folder)
            if !cut, let jump = source.jumpHostID, let remapped = ids[jump] { copy.jumpHostID = remapped }
            let base = copy.name; var suffix = 1
            while result.contains(where: { $0.folder == copy.folder && $0.name.localizedCaseInsensitiveCompare(copy.name) == .orderedSame }) {
                copy.name = base + (suffix == 1 ? " Copy" : " Copy \(suffix)"); suffix += 1
            }
            result.append(copy)
            if !cut { added.append((source.id, copy)) }
        }
        return Plan(profiles: result, folders: names.sorted(), added: added, movedFolders: cut ? mappedRoots : [:])
    }
    private func contained(_ path: String?) -> Bool {
        guard let path else { return false }
        return roots.contains { FolderPaths.contains(path, in: $0) }
    }
}
