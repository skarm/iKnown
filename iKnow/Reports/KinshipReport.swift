import Foundation
import SQLite3

enum KinshipReport {
    static let claimsTitle = "Relationship Hypotheses"
    private struct ScoreRow {
        let id: Int64
        let scores: [Double?]
    }

    static func load(_ source: GraphSource) throws -> Report {
        let db = try LocalStore.tagging.open(source)
        let graph = try? GraphAccess(source)
        let names = (try? graph?.knownNames()) ?? [:]
        let owner = try? graph?.owner()
        let columns = try db.cells("PRAGMA table_info(entity_tagging)")
            .filter { ["DOUBLE", "REAL", "FLOAT"].contains($0[2].text?.uppercased() ?? "") }
            .compactMap { $0[1].text }
        guard !columns.isEmpty else { throw GraphFailure.schema }

        let values = try db.cells("SELECT mdid, \(columns.map(SQLiteDatabase.identifier).joined(separator: ", ")) FROM entity_tagging")
        let rows = values.compactMap { row -> ScoreRow? in
            guard let id = row[0].integer, id != owner else { return nil }
            let scores = row.dropFirst().map { $0.number.map { ($0 * 1e12).rounded() / 1e12 } }
            return ScoreRow(id: id, scores: scores)
        }
        let vectors = columns.indices.map { column in rows.map { $0.scores[column] } }
        let active = columns.indices.filter { vectors[$0].contains { ($0 ?? 0) > 0 } }
        let copies = Dictionary(grouping: active, by: { vectors[$0] }).values
            .filter { $0.count > 1 }
            .sorted { $0[0] < $1[0] }
        let equations = try exactSums(active, vectors)
        let targets = Set(equations.map(\.target))
        let terms = Set(equations.flatMap(\.terms))
        let independent = active.filter { !targets.contains($0) && !terms.contains($0) }
        let composite = columns.firstIndex(of: "familyAndFriends") ?? independent.max { lhs, rhs in
            vectors[lhs].compactMap { $0 }.reduce(0,+) < vectors[rhs].compactMap { $0 }.reduce(0,+)
        }
        let ordered = rows.sorted { lhs, rhs in
            let left = composite.flatMap { lhs.scores[$0] } ?? lhs.scores.compactMap { $0 }.max() ?? 0
            let right = composite.flatMap { rhs.scores[$0] } ?? rhs.scores.compactMap { $0 }.max() ?? 0
            return left == right ? lhs.id < rhs.id : left > right
        }
        let observed = rows.flatMap(\.scores).compactMap { $0 }.filter { $0 > 0 }
        let ladder = Dictionary(grouping: observed, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.0 > $1.0 }

        var result = Report(metrics: [
            Metric("People Scored", Int64(rows.count)), Metric("Relationship Types", Int64(columns.count)),
            Metric("Nonzero Scores", Int64(observed.count))
        ])
        let person = Column("Entity", privateValue: true)
        result.sections.append(ReportSection("Score Matrix", [person] + columns.map { Column($0) },
            ordered.prefix(250).map { [GraphAccess.label($0.id, names)] + $0.scores.map { $0.map(Cell.real) ?? .empty } },
            style: .scores, note: rows.count > 250 ? "The first 250 ranked rows are shown. Statistics include all rows." :
                "Each cell is a value from entity_tagging. Names are drawn from the graph when available."))
        let claims = ordered.flatMap { row in
            active.filter { !independent.contains($0) && (row.scores[$0] ?? 0) > 0 }.map { column in
                (id:row.id,cells:[
                    GraphAccess.label(row.id, names), .text(columns[column]), .real(row.scores[column] ?? 0),
                    .text(targets.contains(column) ? "Sum" : "Individual Score")
                ])
            }
        }.sorted { ($0.cells[2].number ?? 0) > ($1.cells[2].number ?? 0) }.prefix(200)
        result.sections.append(ReportSection(claimsTitle, [person, Column("Relationship"), Column("Score"), Column("Type")],
            claims.map(\.cells), note: "Up to 200 scores are shown in descending order.",
            targets:claims.map { GraphTarget(id:$0.id) }))
        result.sections.append(ReportSection("Column Statistics", [Column("Relationship"), Column("Nonzero"), Column("≥ 0,5"), Column("Maximum")],
            columns.indices.map { i in
                let nonzero = vectors[i].compactMap { $0 }.filter { $0 > 0 }
                return [.text(columns[i]), .integer(Int64(nonzero.count)),
                        .integer(Int64(nonzero.filter { $0 >= 0.5 }.count)), .real(nonzero.max() ?? 0)]
            }))
        result.sections.append(ReportSection("Identical Columns and Exact Sums", [Column("Verification"), Column("Result")],
            copies.map { [.text("Match"), .text($0.map { columns[$0] }.joined(separator: " = "))] } +
            equations.map { [.text("Sum"), .text(columns[$0.target] + " = " + $0.terms.map { columns[$0] }.joined(separator: " + "))] },
            note: "Sums of two or three nonempty columns are checked across all rows."))
        let rankedHeads = independent.sorted {
            let a = vectors[$0].compactMap { $0 }.filter { $0 > 0 }.count
            let b = vectors[$1].compactMap { $0 }.filter { $0 > 0 }.count
            return a == b ? $0 < $1 : a > b
        }
        if let composite {
            let other = rankedHeads.filter { $0 != composite }
            var candidates: [(Int, [Int])] = []
            if other.count >= 2 { candidates.append((composite, Array(other.prefix(2)))) }
            if let second = other.first, !targets.isEmpty { candidates.append((second, targets.sorted())) }
            let comparisons: [[Cell]] = candidates.map { lhs, terms in
                let measured = rows.compactMap { row -> Double? in
                    let values = terms.compactMap { row.scores[$0] }
                    guard let left = row.scores[lhs], values.count == terms.count else { return nil }
                    return left - values.reduce(0, +)
                }
                return [.text(columns[lhs]), .text(terms.map { columns[$0] }.joined(separator: " + ")),
                        .integer(Int64(measured.count)), .integer(Int64(measured.filter { abs($0) > 1e-9 }.count)),
                        .integer(Int64(measured.filter { $0 < -1e-9 }.count))]
            }
            result.sections.append(ReportSection("Composite Score Breakdown Checks",
                [Column("Score"), Column("Sum Tested"), Column("Rows"), Column("Differences"), Column("Score Below the Sum")],
                comparisons))
        }
        result.sections.append(ReportSection("Nonzero Score Distribution", [Column("Value"), Column("Cells")],
            ladder.map { [.text(Cell.real($0.0).label), .integer(Int64($0.1))] }, style: .bars))
        if let composite {
            let bounds: [(String, (Double) -> Bool)] = [
                ("≥ 0,9", { $0 >= 0.9 }), ("0,7–0,9", { $0 >= 0.7 && $0 < 0.9 }),
                ("0,5–0,7", { $0 >= 0.5 && $0 < 0.7 }), ("0,25–0,5", { $0 >= 0.25 && $0 < 0.5 }),
                ("0–0,25", { $0 > 0 && $0 < 0.25 }), ("Exactly 0", { $0 == 0 })
            ]
            let scores = vectors[composite].compactMap { $0 }
            result.sections.append(ReportSection("\(columns[composite]) Thresholds", [Column("Range"), Column("People")],
                bounds.map { [.text($0.0), .integer(Int64(scores.filter($0.1).count))] }, style: .bars))
        }
        if let graph {
            let live = graph.layers.contains(.stable) ? try graph.db.cells("SELECT DISTINCT subject FROM stable_graph") : []
            let expired = graph.layers.contains(.expiredStable) ? try graph.db.cells("SELECT DISTINCT subject FROM expired_stable_graph") : []
            let liveIDs = Set(live.compactMap { $0[0].integer })
            let expiredIDs = Set(expired.compactMap { $0[0].integer }).subtracting(liveIDs)
            let featureDB = try? LocalStore.features.open(source)
            let coverage = try? featureDB?.cells("""
                SELECT viewName,count(DISTINCT subidentifierName)
                FROM kv WHERE viewName IN ('personEntityTaggingFacts','personEntityTagging') GROUP BY viewName
                """)
            var counts: [[Cell]] = [
                [.text("Entities in the Active Graph"), .integer(Int64(rows.filter { liveIDs.contains($0.id) }.count))],
                [.text("Entities Only in the Archive"), .integer(Int64(rows.filter { expiredIDs.contains($0.id) }.count))],
                [.text("Named Entities"), .integer(Int64(rows.filter { names[$0.id] != nil }.count))]
            ]
            counts += (coverage ?? []).map { row in
                [.text(row[0].text == "personEntityTaggingFacts" ? "Features Checked" : "Has a Profile"),row[1]]
            }
            result.sections.append(ReportSection("Graph and Feature Coverage", [Column("Metric"),Column("Entities")],counts))
        }
        result.sections.append(try signals(source, graph, owner, names, columns, ordered))
        result.sections.append(try features(source))
        return result
    }

    private static func exactSums(_ active: [Int], _ vectors: [[Double?]]) throws -> [(target: Int, terms: [Int])] {
        // Positive vectors allow candidates to be rejected early on a single mismatch.
        var equations: [(target: Int, terms: [Int])] = []
        let candidates = Array(active.prefix(36))
        for target in candidates {
            try Task.checkCancellation()
            let eligible = candidates.filter { candidate in
                candidate != target && vectors[candidate] != vectors[target] &&
                zip(vectors[candidate], vectors[target]).allSatisfy { ($0 ?? 0) <= ($1 ?? 0) + 1e-9 }
            }
            func matches(_ terms: [Int]) -> Bool {
                vectors[target].indices.allSatisfy { row in
                    guard let expected = vectors[target][row] else { return false }
                    var sum = 0.0
                    for column in terms {
                        guard let value = vectors[column][row] else { return false }
                        sum += value
                    }
                    return abs(expected - sum) <= 1e-9
                }
            }
            for a in eligible.indices {
                for b in eligible.indices.dropFirst(a + 1) {
                    let pair = [eligible[a], eligible[b]]
                    if matches(pair) {
                        equations.append((target, pair))
                        continue
                    }
                    for c in eligible.indices.dropFirst(b + 1) {
                        let triple = pair + [eligible[c]]
                        if matches(triple) { equations.append((target, triple)) }
                    }
                }
            }
        }
        return equations
    }

    private static func signals(
        _ source: GraphSource, _ graph: GraphAccess?, _ owner: Int64?, _ names: [Int64: String],
        _ columns: [String], _ rows: [ScoreRow]
    ) throws -> ReportSection {
        let fields = [Column("Entity", privateValue: true), Column("Partner"), Column("Family and Friends"),
                      Column("Shared Group"), Column("Family Sharing"), Column("iCloud Family"), Column("Frequent Contact"),
                      Column("Face"), Column("Contacts"), Column("Phone / Email")]
        guard let graph, graph.layers.contains(.stable) else {
            return ReportSection("Corroborating Features", fields, [], note: "The main graph is unavailable.", unavailable: true)
        }
        var membership: Set<Int64> = []
        var circle: Set<Int64> = []
        if let owner {
            let groups = try graph.members(layer: .stable, predicate: "PS753", facet: "PS566")
            membership = groups.values.filter { $0.contains(owner) }.reduce(into: Set<Int64>()) { $0.formUnion($1) }
            circle = Set(try graph.db.cells("""
                SELECT DISTINCT subject FROM stable_graph WHERE object IN (
                   SELECT object FROM stable_graph WHERE subject=? AND object GLOB 'faFamilyCircle:*')
                """, [.integer(owner)]).compactMap { $0[0].integer })
        }
        let references = try graph.db.cells("""
            SELECT subject, max(object GLOB 'phPerson:*'), max(object GLOB 'cnContact:*'),
                           max(relationshipPredicate IN ('PS406','PS407'))
            FROM stable_graph GROUP BY subject
            """)
        let byID = Dictionary(uniqueKeysWithValues: references.compactMap { row -> (Int64, [Cell])? in
            guard let id = row[0].integer else { return nil }
            return (id, Array(row.dropFirst()))
        })
        var archived: [Int64: [Bool]] = [:]
        if graph.layers.contains(.expiredStable) {
            let archive = try graph.db.cells("""
                SELECT e.subject, max(e.predicate='nm_hasVisualIdentifier' OR e.object GLOB 'phPerson:*'),
                       max(e.object GLOB 'cnContact:*'), max(e.predicate='PS520')
                FROM expired_stable_graph e
                WHERE NOT EXISTS (SELECT 1 FROM stable_graph a WHERE a.subject=e.subject)
                GROUP BY e.subject
                """)
            for row in archive {
                if let id = row[0].integer { archived[id] = row.dropFirst().map { $0.integer == 1 } }
            }
        }
        var archivedGroup: Set<Int64> = []
        var archivedCircle: Set<Int64> = []
        if let owner, graph.layers.contains(.expiredStable) {
            let groups = try graph.members(layer: .expiredStable, predicate: "PS753", facet: "PS566")
            archivedGroup = groups.values.filter { $0.contains(owner) }.reduce(into: Set<Int64>()) { $0.formUnion($1) }
            archivedCircle = Set(try graph.db.cells("""
                SELECT DISTINCT subject FROM expired_stable_graph WHERE object IN (
                    SELECT object FROM stable_graph WHERE subject=? AND object GLOB 'faFamilyCircle:*'
                    UNION SELECT object FROM expired_stable_graph WHERE subject=? AND object GLOB 'faFamilyCircle:*'
                )
                """, [.integer(owner), .integer(owner)]).compactMap { $0[0].integer })
        }
        let cloudRows = try? LocalStore.importance.open(source).cells("""
            SELECT entityIdentifier FROM entityImportanceSignalsIDMap WHERE isICloudFamily = 1
            """)
        let cloud = cloudRows.map { Set($0.compactMap { $0[0].integer }) }
        let volume = try? contactVolume(source, owner: owner)
        let topContact = volume?.max { lhs,rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
        let partner = columns.firstIndex(of: "partner")
        let composite = columns.firstIndex(of: "familyAndFriends")
        func mark(_ value: Bool) -> Cell { .text(value ? "Yes" : "—") }
        let displayed = rows.prefix(250).map { row in
            let score = partner.flatMap { row.scores[$0] }.map(Cell.real) ?? .empty
            let head = composite.flatMap { row.scores[$0] }.map(Cell.real) ?? .empty
            let historical = archived[row.id]
            let live = byID[row.id] ?? [.empty, .empty, .empty]
            let refs = live.indices.map { index in
                historical?[index] == true ? Cell.text("Archive") : mark(live[index].integer == 1)
            }
            let group = historical != nil && archivedGroup.contains(row.id) ? Cell.text("Archive") : mark(membership.contains(row.id))
            let family = historical != nil && archivedCircle.contains(row.id) ? Cell.text("Archive") : mark(circle.contains(row.id))
            return [GraphAccess.label(row.id, names), score, head, group,
                    family, cloud.map { mark($0.contains(row.id)) } ?? .empty,
                    volume.map { _ in mark(row.id == topContact) } ?? .empty] + refs
        }
        return ReportSection("Corroborating Features", fields, Array(displayed),
                             note: "Groups, tokens, and references show which records accompany the score.",
                             targets:rows.prefix(250).map { GraphTarget(id:$0.id) })
    }

    private static func contactVolume(_ source: GraphSource, owner: Int64?) throws -> [Int64: Int] {
        let handles = try LocalStore.internalViews.open(source).cells("SELECT handle,id FROM handle_id")
        var entities: [String: Set<Int64>] = [:]
        for row in handles {
            if let handle = row[0].text, let id = row[1].integer, id != owner {
                entities[handle, default: []].insert(id)
            }
        }
        let rows = try LocalStore.interactions.open(source).cells("""
            SELECT DISTINCT e.id,i.rowid FROM entities e
            JOIN interactionEntities ie ON ie.entityRowid=e.rowid
            JOIN interactions i ON i.rowid=ie.interactionRowid
            WHERE e.type='PersonHandle' AND i.domain IN ('Calls','Messages')
            """)
        var counts: [Int64: Set<Int64>] = [:]
        for row in rows {
            guard let handle = row[0].text, let interaction = row[1].integer else { continue }
            for entity in entities[handle,default:[]] { counts[entity,default:[]].insert(interaction) }
        }
        return counts.mapValues(\.count)
    }

    private static func features(_ source: GraphSource) throws -> ReportSection {
        let columns = [Column("Feature"), Column("Checks"), Column("True"), Column("False"),
                       Column("Categories"), Column("Unreadable")]
        let unavailable = ReportSection("Classifier Features", columns, [],
            note: "features.db or its kv table is unavailable.", unavailable: true)
        guard let db = try? LocalStore.features.open(source) else { return unavailable }
        let rows: [(String, ArchivedFeature.Value?)]
        do {
            rows = try db.query("""
                SELECT featureName,value FROM kv WHERE viewName='personEntityTaggingFacts'
                """) { row in
                    (SQLiteDatabase.text(row,0) ?? "—", ArchivedFeature.read(row,1))
                }
        } catch GraphFailure.schema {
            return unavailable
        }
        let grouped = Dictionary(grouping: rows, by: \.0)
        let ledger = grouped.keys.sorted().compactMap { name -> [Cell]? in
            guard let values = grouped[name] else { return nil }
            var yes: Int64 = 0, no: Int64 = 0, category: Int64 = 0, unknown: Int64 = 0
            for (_,value) in values {
                switch value {
                case .boolean(true): yes += 1
                case .boolean(false): no += 1
                case .category: category += 1
                case nil: unknown += 1
                }
            }
            return [.text(name),.integer(Int64(values.count)),.integer(yes),.integer(no),.integer(category),.integer(unknown)]
        }
        return ReportSection("Classifier Features",columns,ledger,
            note: "Feature checks, positive results, and unreadable records are counted separately.")
    }
}
