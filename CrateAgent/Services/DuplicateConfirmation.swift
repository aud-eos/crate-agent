import Foundation

/// Splits one candidate cluster (shared size and partial hash, or shared
/// 120 s fingerprint) into groups confirmed by digest. A group of identical
/// bytes or PCM is `.confirmed`; one joined by a full-length fingerprint
/// match between files whose PCM differs is `.needsListening` and never
/// pre-selected. Files that match no other file, or could not be read, are
/// kept and never offered for cleanup.
enum DuplicateConfirmation {
    struct Member {
        let file: DuplicateFileRow
        let evidence: DuplicateEvidence
    }

    typealias Group = DuplicateFinder.DuplicateGroup<DuplicateFileRow>
    typealias Kept = DuplicateFinder.KeptFile<DuplicateFileRow>

    static func groups(clusterKey: String, mode: DuplicateFinder.Mode, members: [Member]) -> [Group] {
        let evidenceByID = members.reduce(into: [Int64: DuplicateEvidence]()) { evidence, member in
            if let identifier = member.file.id {
                evidence[identifier] = member.evidence
            }
        }
        var kept: [Kept] = []
        var candidates: [Member] = []
        for member in members {
            if case let .unreadable(reason, _) = member.evidence {
                kept.append(Kept(file: member.file, reason: .unreadable(reason)))
            } else {
                candidates.append(member)
            }
        }
        if candidates.contains(where: { member in member.evidence.isPending }) {
            return [Group(groupKey: clusterKey, mode: mode, files: candidates.map(\.file), check: .checking, keptFiles: kept, evidence: evidenceByID)]
        }

        var parents = Array(candidates.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current {
                current = parents[current]
            }
            return current
        }
        for lhs in candidates.indices {
            for rhs in candidates.indices where rhs > lhs && DuplicateEvidence.relation(candidates[lhs].evidence, candidates[rhs].evidence) != .different {
                parents[root(rhs)] = root(lhs)
            }
        }
        let components = Dictionary(grouping: candidates.indices, by: root).values
            .map { indices in indices.sorted() }
            .sorted { lhs, rhs in lhs[0] < rhs[0] }

        var confirmed: [(files: [DuplicateFileRow], check: DuplicateFinder.Check)] = []
        for component in components {
            guard component.count > 1 else {
                kept.append(Kept(file: candidates[component[0]].file, reason: .differs))
                continue
            }
            let first = candidates[component[0]].evidence
            let isIdentical = component.allSatisfy { index in DuplicateEvidence.relation(first, candidates[index].evidence) == .identical }
            confirmed.append((component.map { index in candidates[index].file }, isIdentical ? .confirmed : .needsListening))
        }
        kept.sort { lhs, rhs in lhs.file.path < rhs.file.path }

        guard !confirmed.isEmpty else {
            return [Group(groupKey: clusterKey, mode: mode, files: [], check: .differs, keptFiles: kept)]
        }
        let isWholeCluster = confirmed.count == 1 && kept.isEmpty
        return confirmed.enumerated().map { offset, component in
            let key = isWholeCluster ? clusterKey : "\(clusterKey):\(component.files.compactMap(\.id).min() ?? 0)"
            return Group(groupKey: key, mode: mode, files: component.files, check: component.check, keptFiles: offset == 0 ? kept : [],
                         evidence: evidenceByID.filter { entry in component.files.contains { file in file.id == entry.key } })
        }
    }
}
