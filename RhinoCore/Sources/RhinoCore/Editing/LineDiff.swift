import Foundation

/// What differs between two texts, line by line.
public enum LineDiff {
    public struct Line: Hashable, Sendable {
        public enum Kind: Sendable {
            /// In both texts.
            case same
            /// Only in the new text.
            case added
            /// Only in the old text.
            case removed
        }

        public let kind: Kind
        public let text: String
    }

    /// The lines of both texts in reading order: what stayed, what `new`
    /// adds and what it drops.
    public static func lines(from old: String, to new: String) -> [Line] {
        let before = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let after = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Scripts are short; texts too long to compare cell by cell are
        // shown as one replacing the other.
        guard before.count * after.count <= 4_000_000 else {
            return before.map { Line(kind: .removed, text: $0) } + after.map { Line(kind: .added, text: $0) }
        }

        // Longest common subsequence, filled from the end so it can be read from the start.
        var common = [[Int]](repeating: [Int](repeating: 0, count: after.count + 1), count: before.count + 1)
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                common[i][j] = before[i] == after[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
            }
        }

        var result: [Line] = []
        var i = 0, j = 0
        while i < before.count, j < after.count {
            if before[i] == after[j] {
                result.append(Line(kind: .same, text: before[i]))
                i += 1
                j += 1
            } else if common[i + 1][j] >= common[i][j + 1] {
                result.append(Line(kind: .removed, text: before[i]))
                i += 1
            } else {
                result.append(Line(kind: .added, text: after[j]))
                j += 1
            }
        }
        result += before[i...].map { Line(kind: .removed, text: $0) }
        result += after[j...].map { Line(kind: .added, text: $0) }
        return result
    }
}
