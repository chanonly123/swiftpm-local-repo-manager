import Foundation

// Single source of truth for ranking branch names in the picker sheets
// (switch/create, merge, rebase, delete, recheckout).
enum BranchSearch {
    // Case-insensitive substring filter on `query`, dropping any names in `excluding`,
    // ranked: names that start with the query first, then natural alphabetical order.
    // An empty query returns every branch (minus exclusions) in ranked order.
    static func ranked(_ branches: [String], query: String, excluding: Set<String> = []) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return branches
            .filter { !excluding.contains($0) && (q.isEmpty || $0.lowercased().contains(q)) }
            .sorted { a, b in
                let ap = a.lowercased().hasPrefix(q)
                let bp = b.lowercased().hasPrefix(q)
                if ap != bp { return ap }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
    }
}
