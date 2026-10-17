import Foundation

/// Splits one 120 s fingerprint cluster into groups of files whose decoded
/// audio matches. A group of identical PCM is `.confirmed`; one joined by a
/// cross-format fingerprint match is `.crossFormat` and never pre-selected.
/// Files that match no other file, or could not be decoded, are kept and
/// never offered for cleanup.
enum DuplicateAudioConfirmation {
    struct Member {
        let file: DuplicateFileRow
        let evidence: DuplicateAudioEvidence
    }

    typealias Group = DuplicateFinder.DuplicateGroup<DuplicateFileRow>
    typealias Kept = DuplicateFinder.KeptFile<DuplicateFileRow>

    static func groups(clusterKey: String, members: [Member]) -> [Group] {
        var kept: [Kept] = []
        var candidates: [Member] = []
        for member in members {
            if case let .unreadable(reason) = member.evidence {
                kept.append(Kept(file: member.file, reason: .unreadable(reason)))
            } else {
                candidates.append(member)
            }
        }
        if candidates.contains(where: { member in member.evidence == .pending }) {
            return [Group(groupKey: clusterKey, mode: .perceptual, files: candidates.map(\.file), audioCheck: .checking, keptFiles: kept)]
        }

        let decoded: [(file: DuplicateFileRow, audio: DuplicateAudioEvidence.DecodedAudio)] = candidates.compactMap { member in
            guard case let .decoded(audio) = member.evidence else { return nil }
            return (member.file, audio)
        }
        var parents = Array(decoded.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current {
                current = parents[current]
            }
            return current
        }
        for lhs in decoded.indices {
            for rhs in decoded.indices where rhs > lhs && DuplicateAudioEvidence.relation(decoded[lhs].audio, decoded[rhs].audio) != .different {
                parents[root(rhs)] = root(lhs)
            }
        }
        let components = Dictionary(grouping: decoded.indices, by: root).values
            .map { indices in indices.sorted() }
            .sorted { lhs, rhs in lhs[0] < rhs[0] }

        var confirmed: [(files: [DuplicateFileRow], check: DuplicateFinder.AudioCheck)] = []
        for component in components {
            if component.count == 1 {
                kept.append(Kept(file: decoded[component[0]].file, reason: .audioDiffers))
            } else {
                let isIdentical = Set(component.map { index in decoded[index].audio.pcmDigest }).count == 1
                confirmed.append((component.map { index in decoded[index].file }, isIdentical ? .confirmed : .crossFormat))
            }
        }
        let audioByID = decoded.reduce(into: [Int64: DuplicateAudioEvidence.DecodedAudio]()) { audio, member in
            if let identifier = member.file.id {
                audio[identifier] = member.audio
            }
        }
        kept.sort { lhs, rhs in lhs.file.path < rhs.file.path }

        guard !confirmed.isEmpty else {
            return [Group(groupKey: clusterKey, mode: .perceptual, files: [], audioCheck: .differs, keptFiles: kept)]
        }
        let isWholeCluster = confirmed.count == 1 && kept.isEmpty
        return confirmed.enumerated().map { offset, component in
            let key = isWholeCluster ? clusterKey : "\(clusterKey):\(component.files.compactMap(\.id).min() ?? 0)"
            return Group(groupKey: key, mode: .perceptual, files: component.files, audioCheck: component.check, keptFiles: offset == 0 ? kept : [],
                         audio: audioByID.filter { entry in component.files.contains { file in file.id == entry.key } })
        }
    }
}
