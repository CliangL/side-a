import Foundation

// Each service owns its cursor: retrying B while A is on page 2 must not skip B's page 1.
struct SearchPages {
    struct Entry {
        var tracks: [Track] = []
        var nextPage: Int? = 1
        var error: String?
    }

    private(set) var entries: [SearchCatalog: Entry] = [:]

    mutating func accept(_ tracks: [Track], from catalog: SearchCatalog, page: Int) {
        var entry = entries[catalog] ?? Entry()
        var seen = Set(entry.tracks.map(\.id))
        let new = tracks.filter { seen.insert($0.id).inserted }
        entry.tracks += new
        entry.error = nil
        entry.nextPage = new.isEmpty ? nil : page + 1
        entries[catalog] = entry
    }

    mutating func fail(_ catalog: SearchCatalog, message: String) {
        var entry = entries[catalog] ?? Entry()
        entry.error = message
        entries[catalog] = entry
    }

    func nextPage(for catalog: SearchCatalog) -> Int? {
        guard let entry = entries[catalog] else { return 1 }
        return entry.nextPage
    }

    func merged(in catalogs: [SearchCatalog]) -> [Track] {
        // Interleave equally ranked hits in catalog order, independent of network response order.
        let lists = catalogs.map { entries[$0]?.tracks ?? [] }
        let count = lists.map(\.count).max() ?? 0
        var result: [Track] = []
        for i in 0..<count {
            for items in lists where i < items.count { result.append(items[i]) }
        }
        return result
    }
}
