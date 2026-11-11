import Foundation
import SQLite3

enum GraphRepository {
    private static let rowLimit = 2_000
    private static let connectionLimit = 60

    @concurrent
    static func catalog(source: GraphSource, requestedLayer: GraphLayer, search: String, page: Int) async throws -> Catalog {
        try source.withScope {
            try catalog(in: GraphAccess(source), requestedLayer: requestedLayer, search: search, page: page)
        }
    }

    private static func catalog(in graph: GraphAccess, requestedLayer: GraphLayer, search: String, page: Int) throws -> Catalog {
        guard let layer = graph.layers.contains(requestedLayer) ? requestedLayer : graph.layers.first else {
            throw GraphFailure.schema
        }
        let table = layer.rawValue
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var filter = ""
        var parameters: [SQLiteDatabase.Parameter] = []
        if !query.isEmpty {
            filter = """
                WHERE iknow_contains(display_name, ?) OR CAST(subject AS TEXT) = ?
                OR EXISTS (
                    SELECT 1 FROM \(table) AS aliases
                    WHERE aliases.subject = summaries.subject
                      AND (aliases.predicate IN ('PS33', 'PS312', 'PS441', 'PS546')
                           OR aliases.relationshipPredicate IN ('PS89', 'PS406', 'PS407'))
                      AND iknow_contains(aliases.object, ?)
                )
                """
            parameters = [.text(query), .text(query), .text(query)]
        }
        parameters += [.integer(Int64(Catalog.pageSize + 1)), .integer(Int64(page) * Int64(Catalog.pageSize))]
        let sql = """
            \(summariesSQL(layer, subjects: "SELECT DISTINCT subject FROM \(table)"))
            SELECT subject, display_name, class_code, is_owner FROM summaries
            \(filter)
            ORDER BY is_owner DESC, display_name IS NULL, display_name COLLATE NOCASE, subject
            LIMIT ? OFFSET ?
            """
        let items = try graph.db.query(sql, parameters) { readEntity($0, vocabulary: graph.vocabulary) }
        return Catalog(
            layers: graph.layers, layer: layer, entities: Array(items.prefix(Catalog.pageSize)),
            hasNextPage: items.count > Catalog.pageSize
        )
    }

    @concurrent
    static func detail(source: GraphSource, layer: GraphLayer, id: Int64) async throws -> GraphDetail? {
        try source.withScope {
            try detail(in: GraphAccess(source), layer: layer, id: id)
        }
    }

    private static func detail(in graph: GraphAccess, layer: GraphLayer, id: Int64) throws -> GraphDetail? {
        let db = graph.db
        let availableLayers = graph.layers
        guard availableLayers.contains(layer) else { throw GraphFailure.schema }
        let vocabulary = graph.vocabulary
        guard let entity = try entities(in: db, layer: layer, ids: [id], vocabulary: vocabulary).first
        else { return nil }

        let records = try evidenceRows(in: db, layer: layer, filter: "subject = ?",
                                       parameters: [.integer(id)], vocabulary: vocabulary)
        let outgoing = try evidenceRows(in: db, layer: layer, filter: "subject = ? AND object GLOB 'md:*'",
                                        parameters: [.integer(id)], vocabulary: vocabulary)
        let incoming = try evidenceRows(in: db, layer: layer, filter: "object = ? AND subject <> ?",
                                        parameters: [.text("md:\(id)"), .integer(id)], vocabulary: vocabulary)

        let to = Dictionary(grouping: outgoing.prefix(rowLimit).compactMap { row in
            row.reference.flatMap { $0 == id ? nil : ($0, row) }
        }, by: \.0)
        let from = Dictionary(grouping: incoming.prefix(rowLimit), by: \.subject)
        let neighbors = Set(to.keys).union(from.keys).sorted { lhs, rhs in
            let left = (to[lhs]?.count ?? 0) + (from[lhs]?.count ?? 0)
            let right = (to[rhs]?.count ?? 0) + (from[rhs]?.count ?? 0)
            return left == right ? lhs < rhs : left > right
        }
        let ids = Array(neighbors.prefix(connectionLimit))
        var resolved: [Int64: (Entity, GraphLayer)] = [:]
        for candidate in [layer] + [.stable, .event].filter({ $0 != layer && availableLayers.contains($0) }) {
            let remaining = ids.filter { resolved[$0] == nil }
            for item in try entities(in: db, layer: candidate, ids: remaining, vocabulary: vocabulary) {
                resolved[item.id] = (item, candidate)
            }
        }

        return GraphDetail(
            entity: entity,
            statements: statements(from: records.prefix(rowLimit)),
            connections: ids.map { neighbor in
                Connection(
                    id: neighbor, entity: resolved[neighbor]?.0, layer: resolved[neighbor]?.1,
                    incoming: from[neighbor, default: []], outgoing: to[neighbor, default: []].map(\.1)
                )
            },
            hasMoreStatements: records.count > rowLimit,
            hasMoreConnections: neighbors.count > connectionLimit || outgoing.count > rowLimit || incoming.count > rowLimit
        )
    }

    private static func summariesSQL(_ layer: GraphLayer, subjects: String) -> String {
        let table = layer.rawValue
        return """
            WITH subjects AS (\(subjects)),
            summaries AS (
                SELECT s.subject,
                    COALESCE(
                        (SELECT r.object FROM \(table) AS r
                         WHERE r.subject = s.subject AND r.predicate = 'PS33' AND r.object <> ''
                         ORDER BY r.confidence DESC, length(r.object) DESC, r.object LIMIT 1),
                        NULLIF(trim(
                            COALESCE((SELECT r.object FROM \(table) AS r
                                      WHERE r.subject = s.subject AND r.predicate = 'PS312'
                                      ORDER BY r.confidence DESC, r.object LIMIT 1), '') || ' ' ||
                            COALESCE((SELECT r.object FROM \(table) AS r
                                      WHERE r.subject = s.subject AND r.predicate = 'PS441'
                                      ORDER BY r.confidence DESC, r.object LIMIT 1), '')
                        ), ''),
                        (SELECT r.object FROM \(table) AS r WHERE r.subject = s.subject
                         AND r.relationshipPredicate = 'PS89' AND r.object <> ''
                         ORDER BY r.confidence DESC, r.object LIMIT 1)
                    ) AS display_name,
                    (SELECT r.object FROM \(table) AS r WHERE r.subject = s.subject
                     AND r.predicate = 'PS1' AND r.relationshipId = 0
                     ORDER BY r.confidence DESC, r.object LIMIT 1) AS class_code,
                    EXISTS(SELECT 1 FROM \(table) AS r WHERE r.subject = s.subject
                           AND r.predicate = 'nm_isCurrentUser') AS is_owner
                FROM subjects AS s
            )
            """
    }

    private static func entities(
        in db: SQLiteDatabase, layer: GraphLayer, ids: [Int64], vocabulary: Vocabulary
    ) throws -> [Entity] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let subjects = "SELECT DISTINCT subject FROM \(layer.rawValue) WHERE subject IN (\(placeholders))"
        return try db.query("""
            \(summariesSQL(layer, subjects: subjects))
            SELECT subject, display_name, class_code, is_owner FROM summaries
            """, ids.map(SQLiteDatabase.Parameter.integer)) { readEntity($0, vocabulary: vocabulary) }
    }

    private static func readEntity(_ row: OpaquePointer, vocabulary: Vocabulary) -> Entity {
        let id = sqlite3_column_int64(row, 0)
        let code = SQLiteDatabase.text(row, 2)
        return Entity(
            id: id, name: SQLiteDatabase.text(row, 1) ?? "ID \(id)", classCode: code,
            kind: vocabulary.kind(code), isOwner: sqlite3_column_int(row, 3) != 0
        )
    }

    private static func evidenceRows(
        in db: SQLiteDatabase, layer: GraphLayer, filter: String,
        parameters: [SQLiteDatabase.Parameter], vocabulary: Vocabulary
    ) throws -> [Evidence] {
        // Some layouts do not expose SQLite's implicit rowid. Number the rows
        // in the bounded result after sorting by the stored fields instead.
        try db.query("""
            SELECT row_number() OVER (), records.* FROM (
                SELECT subject, predicate, relationshipId, relationshipPredicate, object,
                       confidence, sources, sourceDuplicates, timestamp
                FROM \(layer.rawValue)
                WHERE \(filter)
                ORDER BY predicate, relationshipId, relationshipPredicate, subject, object,
                         confidence, sources, sourceDuplicates, timestamp
                LIMIT ?
            ) AS records
            """, parameters + [.integer(Int64(rowLimit + 1))]) {
                evidence($0, vocabulary: vocabulary)
            }
    }

    private static func evidence(_ row: OpaquePointer, vocabulary: Vocabulary) -> Evidence {
        let predicate = SQLiteDatabase.text(row, 2) ?? ""
        let facet = SQLiteDatabase.text(row, 4).flatMap { $0.isEmpty ? nil : $0 }
        return Evidence(
            id: sqlite3_column_int64(row, 0),
            subject: sqlite3_column_int64(row, 1),
            predicate: predicate,
            predicateLabel: vocabulary.predicate(predicate),
            relationshipID: sqlite3_column_int64(row, 3),
            facet: facet, facetLabel: facet.map(vocabulary.predicate),
            value: SQLiteDatabase.text(row, 5),
            confidence: SQLiteDatabase.number(row, 6),
            sources: SQLiteDatabase.integer(row, 7),
            sourceRecords: (SQLiteDatabase.text(row, 8) ?? "").split(separator: "\u{1e}").map(String.init),
            writtenAt: SQLiteDatabase.number(row, 9).map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }

    private static func statements(from rows: ArraySlice<Evidence>) -> [Statement] {
        var groups: [Statement.ID: [Evidence]] = [:]
        var order: [Statement.ID] = []
        for row in rows {
            let id: Statement.ID = row.relationshipID == 0
                ? .attribute(row.id)
                : .relationship(predicate: row.predicate, id: row.relationshipID)
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(row)
        }
        return order.map { Statement(id: $0, rows: groups[$0, default: []]) }
    }
}
