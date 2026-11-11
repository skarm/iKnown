import Foundation

struct GraphAccess {
    let db: SQLiteDatabase
    let vocabulary: Vocabulary
    let layers: [GraphLayer]

    init(_ source: GraphSource) throws {
        db = try LocalStore.graph.open(source)
        vocabulary = Vocabulary(source: source)
        let tables = try db.cells("SELECT name FROM sqlite_schema WHERE type = 'table'").compactMap { $0[0].text }
        layers = GraphLayer.allCases.filter { tables.contains($0.rawValue) }
        guard !layers.isEmpty else { throw GraphFailure.schema }
    }

    func names(layer: GraphLayer = .stable) throws -> [Int64: String] {
        guard layers.contains(layer) else { return [:] }
        let rows = try db.cells("""
            WITH ranked AS (
              SELECT subject, predicate, object, row_number() OVER (
                PARTITION BY subject,predicate ORDER BY confidence DESC, length(object) DESC, object) AS rank
              FROM \(layer.rawValue) WHERE predicate IN ('PS33','PS312','PS441') AND object <> ''
            )
            SELECT subject, coalesce(max(CASE WHEN predicate='PS33' THEN object END),
              nullif(trim(coalesce(max(CASE WHEN predicate='PS312' THEN object END),'') || ' ' ||
                          coalesce(max(CASE WHEN predicate='PS441' THEN object END),'')),'')) AS name
            FROM ranked WHERE rank=1 GROUP BY subject
            """)
        var result: [Int64: String] = [:]
        for row in rows {
            if let id = row[0].integer, let name = row[1].text { result[id] = name }
        }
        return result
    }

    func knownNames() throws -> [Int64: String] {
        try names().merging(names(layer: .expiredStable)) { live, _ in live }
    }

    func owner() throws -> Int64? {
        guard layers.contains(.stable) else { return nil }
        return try db.cells("SELECT subject FROM stable_graph WHERE predicate = 'nm_isCurrentUser' LIMIT 1").first?[0].integer
    }

    func members(layer: GraphLayer, predicate: String, facet: String) throws -> [Int64: Set<Int64>] {
        guard layers.contains(layer) else { return [:] }
        let rows = try db.cells("""
            SELECT subject,object FROM \(layer.rawValue)
            WHERE predicate=? AND relationshipPredicate=? AND object GLOB 'md:*'
            """, [.text(predicate), .text(facet)])
        var result: [Int64: Set<Int64>] = [:]
        for row in rows {
            if let subject = row[0].integer, let object = Self.reference(row[1].text) {
                result[subject, default: []].insert(object)
            }
        }
        return result
    }

    static func reference(_ raw: String?) -> Int64? {
        guard let raw, raw.hasPrefix("md:"), let id = Int64(raw.dropFirst(3)), raw == "md:\(id)" else { return nil }
        return id
    }

    static func label(_ id: Int64, _ names: [Int64: String]) -> Cell {
        .text(names[id] ?? "ID \(id)")
    }
}
