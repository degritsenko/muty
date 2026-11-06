import Foundation

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
            guard let folder, let root = roots.first(where: { folder == $0 || folder.hasPrefix($0 + "/") }), let target = mappedRoots[root] else { return destination }
            return target + folder.dropFirst(root.count)
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
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
