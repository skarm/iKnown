import Foundation

struct SocialOverlapIndex: Sendable {
    struct Item: Sendable {
        let title: String
        var date: String?
        var target: GraphTarget?
        var identities: [Int64] = []
    }

    let memberships: [String: Set<String>]
    let items: [String: Item]

    private struct PairEvidence {
        let first: String
        let second: String
        let shared: Set<String>
        let total: Int
        let qualifies: Bool
        var ratio: Double { total == 0 ? 0 : Double(shared.count) / Double(total) }
    }

    func sections(in layer: SocialIndex.Layer, anchor: String, edges: [SocialIndex.Edge]) throws -> [ReportSection] {
        let chats = layer.id == .chats
        var adjacency: [String: Set<String>] = [:]
        for edge in edges {
            adjacency[edge.first, default: []].insert(edge.second)
            adjacency[edge.second, default: []].insert(edge.first)
        }
        var ids: Set<String> = [anchor]
        var pending = [anchor]
        while let id = pending.popLast() {
            try Task.checkCancellation()
            for neighbor in adjacency[id, default: []] where ids.insert(neighbor).inserted {
                pending.append(neighbor)
            }
        }

        let nodes = layer.nodes.filter { ids.contains($0.id) }
        let names = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.title) })
        func title(_ id: String) -> Cell { .text(names[id] ?? id) }
        let memberSets = nodes.map { memberships[$0.id, default: []] }
        let common = memberSets.dropFirst().reduce(memberSets.first ?? []) { $0.intersection($1) }
        let union = memberSets.reduce(into: Set<String>()) { $0.formUnion($1) }
        var pairs: [PairEvidence] = []
        for (offset, node) in nodes.enumerated() {
            try Task.checkCancellation()
            let left = memberSets[offset]
            for other in (offset + 1)..<nodes.count {
                let right = memberSets[other]
                let shared = left.intersection(right)
                pairs.append(PairEvidence(first: node.id, second: nodes[other].id, shared: shared,
                    total: left.count + right.count - shared.count,
                    qualifies: adjacency[node.id, default: []].contains(nodes[other].id)))
            }
        }
        let qualifying = pairs.filter(\.qualifies)
        let weakest = qualifying.min {
            if chats, $0.shared.count != $1.shared.count { return $0.shared.count < $1.shared.count }
            return $0.ratio < $1.ratio
        }
        let density = pairs.isEmpty ? Cell.empty : .real(Double(qualifying.count) / Double(pairs.count))
        let mean = pairs.isEmpty ? Cell.empty : .real(pairs.reduce(0) { $0 + $1.ratio } / Double(pairs.count))
        let summary = ReportSection("Component Coverage", [
            Column("Nodes"), Column("Above Threshold"), Column("Total Pairs"), Column("Density"),
            Column("Minimum Jaccard"), Column("Average Jaccard"), Column("Shared by All"), Column(chats ? "Total Addresses" : "Total Events")
        ], [[.integer(Int64(nodes.count)), .integer(Int64(qualifying.count)), .integer(Int64(pairs.count)),
             density, pairs.map(\.ratio).min().map(Cell.real) ?? .empty, mean, .integer(Int64(common.count)),
             .integer(Int64(union.count))]],
             note: "The component follows chains of pairs that meet the threshold. The average and minimum use every pair.")
        let members = ReportSection("Component Members", [
            Column(chats ? "Chat" : "Participant", privateValue: true), Column(chats ? "Addresses" : "Events")
        ] + (chats ? [Column("Indexed Entities")] : []), nodes.enumerated().map { index, node in
            let set = memberSets[index]
            return [title(node.id), .integer(Int64(set.count))] + (chats
                ? [.integer(Int64(Set(set.flatMap { items[$0]?.identities ?? [] }).count))] : [])
        }, targets: nodes.map(\.target))
        func ordered(_ ids: Set<String>) -> [String] {
            ids.sorted { a, b in
                let left = items[a]?.date ?? "", right = items[b]?.date ?? ""
                return left == right ? a < b : left < right
            }
        }
        let sharedIDs = ordered(common)
        var occurrences: [String: Int] = [:]
        for membership in memberships.values {
            for id in membership.intersection(common) { occurrences[id, default: 0] += 1 }
        }
        let shared = ReportSection(chats ? "Addresses Shared by All Chats" : "Events Shared by All Members", [
            Column(chats ? "Address" : "Event", privateValue: true),
            chats ? Column("Chats in the Log") : Column("Dates", privateValue: true)
        ], sharedIDs.map { id in
            [.text(items[id]?.title ?? id), chats ? .integer(Int64(occurrences[id, default: 0]))
                : items[id]?.date.map(Cell.text) ?? .empty]
        }, targets: sharedIDs.map { items[$0]?.target })
        let columns = [Column("First", privateValue: true), Column("Second", privateValue: true),
            Column("Shared"), Column("Union"), Column("Jaccard"), Column("Threshold"),
            Column("Examples", privateValue: true)]
        func row(_ pair: PairEvidence) -> [Cell] {
            let examples = ordered(pair.shared).prefix(8).map { items[$0]?.title ?? $0 }
            return [title(pair.first), title(pair.second), .integer(Int64(pair.shared.count)),
                    .integer(Int64(pair.total)), .real(pair.ratio), .text(pair.qualifies ? "Threshold Met" : "Below Threshold"),
                    .text(examples.joined(separator: ", "))]
        }
        var result = [summary, members, shared]
        if let weakest {
            result.append(ReportSection("Weakest Pair That Meets the Threshold", columns, [row(weakest)]))
        }
        result.append(ReportSection("All Pairs in the Component", columns, pairs.map(row)))
        return result
    }
}

enum SocialStatements {
    static func load(_ source: GraphSource, kind: SocialIndex.Kind, node: SocialIndex.Node) throws -> [ReportSection] {
        guard let target = node.target else { return [] }
        let graph = try GraphAccess(source)
        let (layer, predicate, facet): (GraphLayer, String, String)
        switch kind {
        case .groups: (layer, predicate, facet) = (.stable, "PS753", "PS566")
        case .work: (layer, predicate, facet) = (.stable, "PS500", "PS45")
        case .events: (layer, predicate, facet) = (.event, "PS232", "PS143")
        default: return []
        }
        guard graph.layers.contains(layer) else { return [] }
        let names = try graph.knownNames().merging(graph.names(layer: layer)) { _, inLayer in inLayer }
        let subjectIsAnchor = kind == .work ? node.isPerson : !node.isPerson
        let restriction = subjectIsAnchor ? "subject=?" : "object=?"
        let anchor: SQLiteDatabase.Parameter = subjectIsAnchor ? .integer(target.id) : .text("md:\(target.id)")
        let roles = kind == .events ? "OR (predicate='PS578' AND relationshipPredicate='PS143') OR predicate='PS580'" : ""
        let evidence = try graph.db.cells("""
            WITH selected AS (
                SELECT DISTINCT subject, predicate, relationshipId FROM \(layer.rawValue)
                WHERE ((predicate=? AND relationshipPredicate=?) \(roles)) AND \(restriction)
            )
            SELECT g.subject,g.relationshipId,g.relationshipPredicate,g.object,g.confidence,
                   g.sources,datetime(g.timestamp+978307200,'unixepoch'),g.predicate
            FROM \(layer.rawValue) g JOIN selected s
                ON s.subject=g.subject AND s.relationshipId=g.relationshipId AND s.predicate=g.predicate
            ORDER BY g.subject,g.relationshipId,g.relationshipPredicate,g.object
            """, [.text(predicate), .text(facet), anchor])
        var targets: [GraphTarget?] = []
        let rows: [[Cell]] = evidence.compactMap { row in
            guard let subject = row[0].integer else { return nil }
            targets.append(.init(id: subject, layer: layer))
            let field = row[2].text ?? ""
            let object: Cell
            if field == "PS1" { object = .text(graph.vocabulary.kind(row[3].text)) }
            else { object = GraphAccess.reference(row[3].text).map { GraphAccess.label($0, names) } ?? row[3] }
            let bits = row[5].integer.map(Evidence.sourceLabels(for:)) ?? []
            return [GraphAccess.label(subject, names), row[1],
                    .text(field.isEmpty ? graph.vocabulary.predicate(row[7].text ?? predicate) : graph.vocabulary.predicate(field)),
                    object, row[4], row[5], .text(bits.joined(separator: ", ")), row[6]]
        }
        return [ReportSection("Original Statements · \(predicate)", [
            Column("Subject", privateValue: true), Column("Relationship ID", privateValue: true), Column("Field"),
            Column("Value", privateValue: true), Column("Confidence"), Column("Mask"),
            Column("Sources"), Column("Recorded", privateValue: true)
        ], rows, targets: targets)]
    }
}

extension SocialStatements {
    static func chatTraffic(_ source: GraphSource, chatID: Int64) throws -> ReportSection {
        let db = try LocalStore.interactions.open(source)
        let (_, inbound, outbound) = try CommunicationsReport.directionExpressions(db)
        return try db.table("Selected Chat Activity", [
            Column("App", privateValue: true), Column("Domain"), Column("Records"), Column("Incoming"),
            Column("Outgoing"), Column("First Record", privateValue: true), Column("Last Record", privateValue: true)
        ], """
            SELECT i.bundleId,i.domain,count(*),\(inbound),\(outbound),
                   datetime(min(i.startDate)+978307200,'unixepoch'),datetime(max(i.startDate)+978307200,'unixepoch')
            FROM interactions i JOIN (
                SELECT DISTINCT interactionRowid FROM interactionEntities WHERE entityRowid=?
            ) l ON l.interactionRowid=i.rowid
            GROUP BY i.bundleId,i.domain ORDER BY 3 DESC,1,2
            """, bindings: [.integer(chatID)])
    }
}


enum SocialCatalog {
    static func overview(_ networks: [SocialIndex.Layer], owner: Int64?) -> SocialIndex.Layer {
        var nodes: [String: SocialIndex.Node] = [:]
        var edges: [SocialIndex.Edge] = []
        let kinds: Set<SocialIndex.Kind> = [.groups, .work, .events, .closeness, .archive]
        for layer in networks where kinds.contains(layer.id) {
            let byID = Dictionary(uniqueKeysWithValues: layer.nodes.map { ($0.id, $0) })
            func key(_ node: SocialIndex.Node) -> String {
                guard let target = node.target else { return node.id }
                let event = target.layer == .event || target.layer == .expiredEvent
                return (event ? "event-" : "entity-") + String(target.id)
            }
            for node in layer.nodes {
                let id = key(node)
                let previous = nodes[id]
                let archived = node.target?.layer == .expiredStable || node.target?.layer == .expiredEvent
                let preferred = archived ? previous ?? node : node
                let role: SocialIndex.Role? = node.target?.id == owner && owner != nil ? .owner : node.role ?? previous?.role
                nodes[id] = .init(id: id, title: preferred.title, symbol: preferred.symbol, target: preferred.target,
                                  isPerson: preferred.isPerson, role: role)
            }
            for edge in layer.edges where layer.id != .archive || edge.archived {
                guard let first = byID[edge.first], let second = byID[edge.second] else { continue }
                edges.append(.init(first: key(first), second: key(second), label: edge.label, weight: edge.weight,
                                   archived: edge.archived, evidenceKey: edge.evidenceKey, kind: layer.id))
            }
        }
        var seen: Set<String> = []
        return .init(id: .overview, nodes: nodes.values.sorted { $0.id < $1.id },
                     edges: edges.filter { seen.insert($0.id).inserted })
    }

    static func sections(
        _ graph: GraphAccess, networks: [SocialIndex.Layer], owner: Int64?
    ) throws -> [ReportSection] {
        guard let circles = networks.first(where: { $0.id == .circles }) else { return [] }
        let attendance = circles.overlap?.memberships ?? [:]
        let eventEdges = networks.first { $0.id == .events }?.edges ?? []
        let groups = networks.first { $0.id == .groups }?.edges ?? []
        let work = networks.first { $0.id == .work }?.edges ?? []
        let close = networks.first { $0.id == .closeness }?.edges ?? []
        var reasons: [String: Set<String>] = [:]
        for edge in eventEdges where edge.label.hasPrefix("Organizer") || edge.label.hasPrefix("Sender") {
            reasons[edge.second, default: []].insert(edge.label.components(separatedBy: " · ").first ?? edge.label)
        }
        for edge in groups { reasons[edge.second, default: []].insert("Group Member") }
        for edge in work { reasons[edge.second, default: []].insert("Has an Employer") }
        for edge in close where (edge.weight ?? 0) >= 0.5 {
            reasons[edge.second, default: []].insert(edge.label)
        }
        let ids = reasons.keys.compactMap { key -> (String, Int64)? in
            guard attendance[key, default: []].isEmpty, let id = Int64(key.dropFirst("person-".count)), id != owner else { return nil }
            return (key, id)
        }.sorted { $0.1 < $1.1 }
        let names = try graph.knownNames()
        var result = [ReportSection("People Without Event Participation Records", [
            Column("Person", privateValue: true), Column("Connections in the Graph")
        ], ids.map { key, id in
            [GraphAccess.label(id, names), .text(reasons[key, default: []].sorted().joined(separator: ", "))]
        }, targets: ids.map { GraphTarget(id: $0.1) })]

        for layer in networks where layer.overlap != nil {
            let chats = layer.id == .chats
            let steps: [Double] = chats ? (1...10).map(Double.init) : (1...19).map { Double($0) / 20 }
            var rows: [[Cell]] = []
            for step in steps {
                try Task.checkCancellation()
                let eligible = layer.edges.filter { chats ? Double($0.sharedCount) >= step : ($0.weight ?? 0) >= step }
                var parent: [String: String] = [:]
                func root(_ id: String) -> String {
                    var value = id
                    while let next = parent[value], next != value { value = next }
                    return value
                }
                for edge in eligible {
                    let left = root(edge.first), right = root(edge.second)
                    parent[left] = right
                    if parent[right] == nil { parent[right] = right }
                }
                var components: [String: Int] = [:]
                for node in parent.keys { components[root(node), default: 0] += 1 }
                rows.append([chats ? .integer(Int64(step)) : .real(step), .integer(Int64(eligible.count)),
                             .integer(Int64(components.count)), .integer(Int64(layer.nodes.count - parent.count)),
                             .integer(Int64(components.values.max() ?? (layer.nodes.isEmpty ? 0 : 1)))])
            }
            result.append(ReportSection(chats ? "Chats at Different Thresholds" : "Circles at Different Thresholds", [
                Column(chats ? "Shared Addresses" : "Jaccard"), Column("Pairs"), Column("Components"),
                Column("Isolated Nodes"), Column("Largest Component Size")
            ], rows))
        }
        if let owner, graph.layers.contains(.stable) {
            let rows = try graph.db.cells("""
                SELECT confidence,sources,datetime(timestamp+978307200,'unixepoch')
                FROM stable_graph WHERE subject=? AND predicate='nm_isCurrentUser'
                """, [.integer(owner)])
            result.append(ReportSection("Graph Owner", [
                Column("Person", privateValue: true), Column("Invitations"), Column("Confidence"), Column("Mask"),
                Column("Sources"), Column("Recorded", privateValue: true)
            ], rows.map { row in
                let count = eventEdges.filter { $0.second == "person-\(owner)" && $0.label.hasPrefix("Invitation") }.count
                return [GraphAccess.label(owner, names), .integer(Int64(count)), row[0], row[1],
                        .text(row[1].integer.map(Evidence.sourceLabels(for:))?.joined(separator: ", ") ?? ""), row[2]]
            }, targets: rows.map { _ in GraphTarget(id: owner) }))
        }
        return result
    }
}
