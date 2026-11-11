import Foundation

enum DerivedReports {
    private struct Overlap {
        let a: Int64
        let b: Int64
        let shared: Int64
        let total: Int64
        var score: Double { Double(shared) / Double(total) }
    }

    static func social(_ graph: GraphAccess, _ source: GraphSource) throws -> Report {
        let names = try graph.knownNames()
        let owner = try graph.owner()
        let groups = try graph.members(layer: .stable, predicate: "PS753", facet: "PS566")
        let employers = try graph.members(layer: .stable, predicate: "PS500", facet: "PS45")
        let events = try graph.members(layer: .event, predicate: "PS232", facet: "PS143")
        let eventNames = try graph.names(layer: .event)
        let people = Column("Participants", privateValue: true, format: .people)
        let count = Column("People")
        func list(_ ids: Set<Int64>) -> Cell {
            .names(ids.sorted().map { names[$0] ?? "ID \($0)" })
        }
        let storedGroups = groups.sorted { $0.key < $1.key }.prefix(200).map { id, members in
            [GraphAccess.label(id,names), .integer(Int64(members.count)), list(members)]
        }
        var byEmployer: [Int64: Set<Int64>] = [:]
        for (employee, workplaces) in employers {
            for employer in workplaces { byEmployer[employer, default: []].insert(employee) }
        }
        let storedEmployers = byEmployer.sorted { $0.key < $1.key }.prefix(200).map { id, members in
            [GraphAccess.label(id,names), .integer(Int64(members.count)), list(members)]
        }
        let overlaps = try meetingOverlaps(events, owner: owner)
        var networks: [SocialIndex.Layer] = [
            membershipNetwork(.groups, memberships: groups, hosts: names, people: names),
            membershipNetwork(.work, memberships: byEmployer, hosts: names, people: names),
            membershipNetwork(.events, memberships: events, hosts: eventNames, people: names)
        ]
        var attendance: [String: Set<String>] = [:]
        var eventItems: [String: SocialOverlapIndex.Item] = [:]
        for (event, members) in events {
            let key = String(event)
            for member in members where member != owner {
                attendance["person-\(member)", default: []].insert(key)
            }
            eventItems[key] = .init(title: eventNames[event] ?? "ID \(event)", target: .init(id: event, layer: .event))
        }
        if graph.layers.contains(.event) {
            for row in try graph.db.cells("""
                SELECT subject, min(day), max(day) FROM (
                    SELECT subject, printf('%04d-%02d-%02d', json_extract(object,'$.year'),
                        json_extract(object,'$.month'),json_extract(object,'$.day')) AS day
                    FROM event_graph WHERE relationshipPredicate='PS29'
                    AND CASE WHEN json_valid(object) THEN json_extract(object,'$.year') IS NOT NULL ELSE 0 END
                ) GROUP BY subject
                """) {
                guard let id = row[0].integer, let first = row[1].text, let last = row[2].text else { continue }
                eventItems[String(id)]?.date = first == last ? first : "\(first) – \(last)"
            }
        }
        let storedEvents = events.sorted { $0.key < $1.key }.prefix(200).map { id, members in
            let date = eventItems[String(id)]?.date.map(Cell.text) ?? .empty
            return [GraphAccess.label(id,eventNames), date, .integer(Int64(members.count)), list(members)]
        }
        let circleIDs = Set(events.values.flatMap { $0 }).filter { $0 != owner }
        networks.append(SocialIndex.Layer(id: .circles,
            nodes: circleIDs.sorted().map { personNode($0, names: names) },
            edges: overlaps.map { edge in
                SocialIndex.Edge(first:"person-\(edge.a)",second:"person-\(edge.b)",
                    label:"\(edge.shared) of \(edge.total) events shared",weight:edge.score)
            }, overlap: .init(memberships: attendance, items: eventItems)))
        var report = Report(metrics: [
            Metric("Groups in the Graph", Int64(groups.count)), Metric("Employers", Int64(byEmployer.count)),
            Metric("Events with Participants", Int64(events.count))
        ], sections: [
            ReportSection("Groups in the Graph", [Column("Group",privateValue:true),count,people], storedGroups),
            ReportSection("Employer Connections", [Column("Employer",privateValue:true),count,people], storedEmployers),
            ReportSection("Shared Event Invitations", [Column("Event",privateValue:true),Column("Date",privateValue:true),count,people], storedEvents)
        ])
        let thresholds = [0.15, 0.25, 0.5, 0.75]
        let analysis = thresholds.flatMap { threshold in
            components(overlaps, threshold: threshold).map { members in
                [Cell.real(threshold), .integer(Int64(members.count)), list(members)]
            }
        }
        report.sections.append(ReportSection("Circles Based on Shared Events", [Column("Threshold",format:.percent),count,people], analysis,
            note: "iKnow analysis. A circle is a connected component based on Jaccard similarity. The graph owner is excluded. A pair in the same circle may be connected through other participants."))
        report.sections.append(ReportSection("Overlap by Pair", [
            Column("Participant A",privateValue:true),Column("Participant B",privateValue:true),Column("Shared"),Column("Total"),Column("Jaccard",format:.percent)
        ], overlaps.prefix(250).map { overlap in [
            GraphAccess.label(overlap.a,names),GraphAccess.label(overlap.b,names),.integer(overlap.shared),
            .integer(overlap.total),.real(overlap.score)
        ]}, note: "Up to 250 pairs, ordered by overlap."))
        if let owner, let close = try? closenessNetwork(source, owner: owner, names: names, groups: groups) {
            networks.append(close)
            let scores = close.edges.filter { ($0.weight ?? 0) >= 0.5 }
            let byID = Dictionary(uniqueKeysWithValues: close.nodes.map { ($0.id, $0) })
            report.sections.append(ReportSection("Closeness as Scored by Apple",
                [Column("Entity",privateValue:true),Column("Score",format:.score)], scores.map {
                    [.text(byID[$0.second]?.title ?? "—"), $0.weight.map(Cell.real) ?? .empty]
                }, targets: scores.map { byID[$0.second]?.target }))
        }
        if let db = try? LocalStore.interactions.open(source) {
            report.sections.append(try db.table("Group Chats", [Column("Chat",privateValue:true),Column("Records"),Column("Apps")], """
                SELECT coalesce(CASE WHEN json_valid(e.fields) THEN json_extract(e.fields,'$.name') END, 'ID ' || e.rowid),
                       count(DISTINCT i.rowid),count(DISTINCT i.bundleId)
                FROM entities e JOIN interactionEntities l ON l.entityRowid=e.rowid
                JOIN interactions i ON i.rowid=l.interactionRowid
                WHERE e.type='MessageGroup' GROUP BY e.rowid ORDER BY count(DISTINCT i.rowid) DESC LIMIT 200
                """))
            report.sections.append(try db.table("Shared Participants in Group Chats",
                [Column("Chat A",privateValue:true),Column("Chat B",privateValue:true),Column("Shared Addresses")], """
                WITH membership AS (
                    SELECT DISTINCT g.rowid AS channel,p.id AS address FROM entities g
                    JOIN interactionEntities a ON a.entityRowid=g.rowid
                    JOIN interactionEntities b ON b.interactionRowid=a.interactionRowid
                    JOIN entities p ON p.rowid=b.entityRowid AND p.type='PersonHandle'
                    WHERE g.type='MessageGroup' AND p.id IS NOT NULL
                )
                SELECT CAST(a.channel AS TEXT),CAST(b.channel AS TEXT),count(*)
                FROM membership a JOIN membership b ON b.address=a.address AND b.channel>a.channel
                GROUP BY 1,2 ORDER BY count(*) DESC LIMIT 180
                """, note: "Chat participants are identified by addresses in the log."))
        }
        if let db = try? LocalStore.interactions.open(source), let chat = try? chatNetwork(db, source: source) {
            networks.append(chat)
        }
        let archive = try ParityReports.archiveNetwork(graph)
        if !archive.edges.isEmpty { networks.append(archive) }
        if let interactions = try? LocalStore.interactions.open(source),
           let participants = try ParityReports.chatMembers(source,interactions,names:names) {
            report.sections.append(participants)
        }
        let organizers = try graph.members(layer: .event, predicate: "PS578", facet: "PS143")
        let senders = try graph.members(layer: .event, predicate: "PS580", facet: "")
        if let slot = networks.firstIndex(where: { $0.id == .events }) {
            let base = networks[slot]
            let extra = [
                membershipNetwork(.events, memberships: organizers, hosts: eventNames, people: names, labelOverride: "Organizer · PS578 / PS143"),
                membershipNetwork(.events, memberships: senders, hosts: eventNames, people: names, labelOverride: "Sender · PS580")
            ]
            var seen = Set(base.nodes.map(\.id))
            networks[slot] = .init(id: .events, nodes: base.nodes + extra.flatMap(\.nodes).filter { seen.insert($0.id).inserted },
                                   edges: base.edges + extra.flatMap(\.edges))
        }
        report.sections += try SocialCatalog.sections(graph, networks: networks, owner: owner)
        report.social = SocialIndex(layers: [SocialCatalog.overview(networks, owner: owner)] + networks)
        return report
    }

    private static func personNode(_ id: Int64, names: [Int64:String]) -> SocialIndex.Node {
        SocialIndex.Node(id:"person-\(id)",title:names[id] ?? "ID \(id)",symbol:"person.fill",
                         target:GraphTarget(id:id),isPerson:true)
    }

    private static func membershipNetwork(
        _ kind: SocialIndex.Kind, memberships: [Int64:Set<Int64>], hosts: [Int64:String], people: [Int64:String],
        labelOverride: String? = nil
    ) -> SocialIndex.Layer {
        let hostIDs = memberships.keys.sorted { a,b in
            let ac = memberships[a,default:[]].count, bc = memberships[b,default:[]].count
            return ac == bc ? a < b : ac > bc
        }.prefix(160)
        let layer: GraphLayer = kind == .events ? .event : .stable
        let (symbol, label): (String,String) = switch kind {
        case .work: ("building.2.fill", "Employer · PS500 / PS45")
        case .events: ("calendar", "Invitation · PS232 / PS143")
        default: ("person.2.fill", "Group Member · PS753 / PS566")
        }
        var memberIDs: Set<Int64> = []
        var nodes: [SocialIndex.Node] = []
        var edges: [SocialIndex.Edge] = []
        for id in hostIDs {
            let key = "host-\(id)"
            nodes.append(SocialIndex.Node(id:key,title:hosts[id] ?? "ID \(id)",symbol:symbol,
                                          target:GraphTarget(id:id,layer:layer),isPerson:false))
            for member in memberships[id,default:[]].sorted().prefix(120) {
                memberIDs.insert(member)
                edges.append(SocialIndex.Edge(first:key,second:"person-\(member)",label:labelOverride ?? label,weight:nil))
            }
        }
        nodes += memberIDs.sorted().map { personNode($0,names:people) }
        return SocialIndex.Layer(id:kind,nodes:nodes,edges:edges)
    }

    private static func closenessNetwork(
        _ source: GraphSource, owner: Int64, names: [Int64: String], groups: [Int64: Set<Int64>]
    ) throws -> SocialIndex.Layer {
        let db = try LocalStore.tagging.open(source)
        let fields = try db.columns(in: "entity_tagging")
        let kinshipHeads = ["mother", "father", "sister", "brother", "partner", "son", "daughter"]
            .filter { fields[$0] != nil }.map { "coalesce(" + SQLiteDatabase.identifier($0) + ",0)>0" }
        let family = kinshipHeads.isEmpty ? "0" : "max(" + kinshipHeads.joined(separator: " OR ") + ")"
        let rows = try db.cells("""
            SELECT mdid,max(familyAndFriends),\(family) FROM entity_tagging
            WHERE familyAndFriends IS NOT NULL AND mdid<>? GROUP BY mdid ORDER BY 2 DESC,1
            """, [.integer(owner)])
        let household = groups.values.filter { $0.contains(owner) }.reduce(into: Set<Int64>()) { $0.formUnion($1) }
        var own = personNode(owner, names: names)
        own.role = .owner
        var nodes = [own]
        var edges: [SocialIndex.Edge] = []
        for row in rows {
            guard let id = row[0].integer, let score = row[1].number else { continue }
            var node = personNode(id, names: names)
            node.role = row[2].integer == 1 || household.contains(id) ? .family : .close
            nodes.append(node)
            edges.append(.init(first: own.id, second: node.id,
                label: "familyAndFriends · " + score.formatted(.number.locale(.iKnow).precision(.fractionLength(2...4))), weight: score))
        }
        return .init(id: .closeness, nodes: nodes, edges: edges)
    }

    private static func chatNetwork(_ db: SQLiteDatabase, source: GraphSource) throws -> SocialIndex.Layer {
        let channels = try db.cells("""
            SELECT rowid,CASE WHEN json_valid(fields) THEN json_extract(fields,'$.name') END
            FROM entities WHERE type='MessageGroup' ORDER BY rowid
            """)
        let nodes = channels.compactMap { row -> SocialIndex.Node? in
            guard let id = row[0].integer else { return nil }
            return SocialIndex.Node(id:String(id),title:row[1].text ?? "Chat \(id)",symbol:"bubble.left.fill",
                                    target:nil,isPerson:false)
        }
        var byChat: [String: Set<String>] = [:]
        var byHandle: [String: Set<String>] = [:]
        for row in try db.cells("""
            SELECT DISTINCT g.rowid,p.id FROM entities g
            JOIN interactionEntities a ON a.entityRowid=g.rowid
            JOIN interactionEntities b ON b.interactionRowid=a.interactionRowid
            JOIN entities p ON p.rowid=b.entityRowid AND p.type='PersonHandle'
            WHERE g.type='MessageGroup' AND p.id IS NOT NULL
            """) {
            guard let id = row[0].integer, let handle = row[1].text else { continue }
            byChat[String(id), default: []].insert(handle)
            byHandle[handle, default: []].insert(String(id))
        }
        var items = Dictionary(uniqueKeysWithValues: byHandle.keys.map {
            ($0, SocialOverlapIndex.Item(title: $0))
        })
        if let handles = try? LocalStore.internalViews.open(source).cells("SELECT handle,id FROM handle_id") {
            for row in handles {
                if let handle = row[0].text, let id = row[1].integer { items[handle]?.identities.append(id) }
            }
        }
        struct ChatPair: Hashable {
            let first: String
            let second: String
        }
        var shared: [ChatPair: Int] = [:]
        for chats in byHandle.values {
            try Task.checkCancellation()
            let ordered = chats.sorted()
            for (offset, first) in ordered.enumerated() {
                for second in ordered.dropFirst(offset + 1) {
                    shared[.init(first: first, second: second), default: 0] += 1
                }
            }
        }
        let edges = shared.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return ($0.key.first, $0.key.second) < ($1.key.first, $1.key.second)
        }.map { pair, count in
            let union = byChat[pair.first, default: []].count + byChat[pair.second, default: []].count - count
            return SocialIndex.Edge(first: pair.first, second: pair.second, label: "\(count) shared addresses",
                                    weight: Double(count) / Double(union), sharedCount: count)
        }
        return SocialIndex.Layer(id: .chats, nodes: nodes, edges: edges, overlap: .init(memberships: byChat, items: items))
    }

    private static func meetingOverlaps(_ events: [Int64: Set<Int64>], owner: Int64?) throws -> [Overlap] {
        var sizes: [Int64: Int64] = [:]
        var shared: [Pair.Key: Int64] = [:]
        for people in events.values {
            try Task.checkCancellation()
            let ids = people.filter { $0 != owner }.sorted()
            for (offset, a) in ids.enumerated() {
                sizes[a,default:0] += 1
                for b in ids.dropFirst(offset+1) { shared[Pair.Key(first:a,second:b),default:0] += 1 }
            }
        }
        return shared.map { key, value in
            Overlap(a:key.first,b:key.second,shared:value,total:sizes[key.first,default:0]+sizes[key.second,default:0]-value)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.a,$0.b) < ($1.a,$1.b)
        }
    }

    private static func components(_ overlaps: [Overlap], threshold: Double) -> [Set<Int64>] {
        var adjacent: [Int64: Set<Int64>] = [:]
        for edge in overlaps.prefix(while: { $0.score >= threshold }) {
            adjacent[edge.a,default:[]].insert(edge.b)
            adjacent[edge.b,default:[]].insert(edge.a)
        }
        var visited: Set<Int64> = []
        var groups: [Set<Int64>] = []
        for root in adjacent.keys.sorted() where !visited.contains(root) {
            var queue = [root]
            var group: Set<Int64> = []
            while let current = queue.popLast() {
                guard visited.insert(current).inserted else { continue }
                group.insert(current)
                queue.append(contentsOf: adjacent[current,default:[]].subtracting(visited))
            }
            groups.append(group)
        }
        return groups.sorted { lhs,rhs in
            lhs.count == rhs.count ? (lhs.min() ?? 0) < (rhs.min() ?? 0) : lhs.count > rhs.count
        }
    }

    static func apps(_ graph: GraphAccess, _ source: GraphSource) throws -> Report {
        guard graph.layers.contains(.stable) else { throw GraphFailure.schema }
        let names = try graph.knownNames()
        let apps = try graph.db.cells("""
            SELECT g.subject,g.object,
              (SELECT object FROM stable_graph s WHERE s.subject=g.subject AND s.predicate='nm_applicationIdentifier' LIMIT 1),
              (SELECT object FROM stable_graph s WHERE s.subject=g.subject AND s.predicate='PS194' AND object GLOB 'md:*' LIMIT 1),
              (SELECT object FROM stable_graph s WHERE s.subject=g.subject AND object GLOB 'lsBundleRecord:*' LIMIT 1),
              date((SELECT min(timestamp) FROM stable_graph s WHERE s.subject=g.subject AND s.timestamp>0)+978307200,'unixepoch')
            FROM stable_graph g WHERE g.predicate='nm_bundleID' GROUP BY g.subject,g.object ORDER BY g.object COLLATE NOCASE,g.subject
            """)
        var verified: Int64 = 0
        var publishers: [Int64: Int64] = [:]
        var inventory = apps.compactMap { row -> [Cell]? in
            guard let id = row[0].integer, let bundle = row[1].text else { return nil }
            let matches = row[4].text.map { $0 == "lsBundleRecord:" + GraphReports.digest(bundle) }
            if matches == true { verified += 1 }
            let publisher = GraphAccess.reference(row[3].text)
            if let publisher { publishers[publisher,default:0] += 1 }
            return [.text(bundle),GraphAccess.label(id,names),row[2],
                publisher.map { GraphAccess.label($0,names) } ?? .empty,row[4],
                matches.map { .text($0 ? "Matched" : "Different") } ?? .empty,row[5]]
        }
        var note = "Tokens are checked locally as Base64(SHA-256(bundle ID))."
        if inventory.isEmpty, let fallback = try? BiomeInventory.apps(source), !fallback.isEmpty {
            inventory = fallback.map { [.text($0.bundle),$0.name.map(Cell.text) ?? .empty,$0.version.map(Cell.text) ?? .empty,
                                        .empty,.empty,.empty,.empty] }
            note = "Inventory from the Biome App.InstalledApp stream. The third column shows the app version."
        }
        let publisherMetadata = try graph.db.cells("""
            SELECT subject,group_concat(DISTINCT CASE WHEN predicate='PS1' THEN object END),
                   max(predicate='nm_teamIdentifier')
            FROM stable_graph WHERE predicate IN ('PS1','nm_teamIdentifier')
            GROUP BY subject
            """)
        var metadata: [Int64: [Cell]] = [:]
        for row in publisherMetadata {
            if let id = row[0].integer { metadata[id] = Array(row.dropFirst()) }
        }
        func publisherClasses(_ id: Int64) -> Cell {
            let codes = metadata[id]?.first?.text?.split(separator: ",") ?? []
            return .text(codes.map { graph.vocabulary.kind(String($0)) }.sorted().joined(separator: ", "))
        }
        let publishersInOrder = publishers.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var report = Report(metrics: [Metric("Apps", Int64(inventory.count)),Metric("Matched Tokens", verified),
                                      Metric("Publishers",Int64(publishers.count))], sections: [
            ReportSection("Installed Apps", [
                Column("Bundle ID",privateValue:true),Column("Name",privateValue:true),Column("App ID / Version",privateValue:true),
                Column("Publisher",privateValue:true),Column("Token",privateValue:true),Column("Verification"),Column("First Record")
            ], inventory, note: note),
            ReportSection("Publishers in the Graph", [
                Column("Publisher",privateValue:true),Column("Apps"),Column("Classes"),Column("Has Team ID")
            ], publishersInOrder.map { id, count in
                [GraphAccess.label(id,names),.integer(count),publisherClasses(id),.integer(metadata[id]?.last?.integer ?? 0)]
            }, targets: publishersInOrder.map { GraphTarget(id: $0.key) })
        ])
        let (index, spaces) = try TokenIndex.load(graph)
        report.tokens = index
        report.sections.append(spaces)
        if graph.layers.contains(.expiredStable) {
            report.sections.append(try graph.db.table("Archived Apps",
                [Column("Bundle ID",privateValue:true),Column("Rows")], """
                SELECT object,count(*) FROM expired_stable_graph WHERE predicate='nm_bundleID' GROUP BY object ORDER BY object
                """))
        }
        let byPublisherName = Dictionary(grouping: publishers.keys.compactMap { id in names[id].map { ($0,id) } },
                                         by: { $0.0 })
        report.sections.append(ReportSection("Duplicate Publisher Names", [
            Column("Title",privateValue:true),Column("Entities"),Column("Apps")
        ], byPublisherName.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }.map { name, ids in
            [.text(name),.integer(Int64(ids.count)),.integer(ids.reduce(0) { $0 + publishers[$1.1, default: 0] })]
        }))
        let aliases = try graph.db.cells("""
            SELECT DISTINCT s.subject,s.object FROM stable_graph s
            WHERE s.object GLOB 'lsBundleRecord:*' AND NOT EXISTS (
                SELECT 1 FROM stable_graph b WHERE b.subject=s.subject AND b.predicate='nm_bundleID'
            ) ORDER BY s.subject,s.object
            """)
        let byHash = Dictionary(grouping: inventory.compactMap { $0[0].text },
                                by: { TokenIndex.bare(GraphReports.digest($0)) })
        let aliasRows: [(Int64, [Cell])] = aliases.compactMap { row in
            guard let id = row[0].integer, let token = row[1].text else { return nil }
            let matches = byHash[TokenIndex.bare(token), default: []].sorted()
            return (id, [GraphAccess.label(id,names),publisherClasses(id),.integer(metadata[id]?.last?.integer ?? 0),
                         row[1],.text(matches.joined(separator: ", "))])
        }
        report.sections.append(ReportSection("App Tokens on Other Entities", [
            Column("Entity",privateValue:true),Column("Classes"),Column("Has Team ID"),
            Column("Token",privateValue:true),Column("Matching Bundle ID",privateValue:true)
        ], aliasRows.map(\.1), targets: aliasRows.map { GraphTarget(id: $0.0) }))

        let installed = Set(inventory.compactMap { $0[0].text })
        var journals: [[Cell]] = []
        for store in [LocalStore.interactions, .internalViews] {
            guard let db = try? store.open(source) else { continue }
            let tables = try db.cells("SELECT name FROM sqlite_schema WHERE type IN ('table','view') AND name NOT GLOB 'sqlite_*' ORDER BY name")
            for row in tables {
                guard let table = row[0].text else { continue }
                let fields = try db.columns(in: table)
                guard let field = fields.keys.sorted().first(where: { ["bundleid", "bundle_id"].contains($0.lowercased()) }) else { continue }
                let column = SQLiteDatabase.identifier(field)
                let identifier = SQLiteDatabase.identifier(table)
                guard let rows = try? db.cells("""
                    SELECT \(column),count(*) FROM \(identifier) WHERE nullif(\(column),'') IS NOT NULL GROUP BY 1 ORDER BY 2 DESC,1
                    """) else { continue }
                journals += rows.map { row in
                    [.text(store.rawValue),.text(table),row[0],row[1],.text(installed.contains(row[0].label) ? "Yes" : "—")]
                }
            }
        }
        report.sections.append(ReportSection("Apps in Activity Logs", [
            Column("Database"),Column("Table"),Column("Bundle ID",privateValue:true),Column("Records"),Column("In Inventory")
        ], journals))
        return report
    }

    static func consumers(_ source: GraphSource) throws -> Report {
        let db = try LocalStore.views.open(source)
        let size = try db.count("SELECT count(*) FROM viewConfigRecord")
        var report = Report(metrics:[Metric("Views",size)])
        report.sections.append(try db.table("View Catalog",[
            Column("View"),Column("Generation"),Column("Type"),Column("File"),Column("Table"),Column("Stream"),Column("Target",privateValue:true)
        ], """
            SELECT name,generationType,artifactType,artifactPath,artifactTable,writeToStream,target
            FROM viewConfigRecord ORDER BY name
            """))
        report.sections.append(try db.table("Subscribers and Schedules",[
            Column("Source"),Column("Frequency"),Column("Listeners"),Column("Views")
        ], """
            SELECT sourceType,schedule,count(*),count(DISTINCT viewOrderedId)
            FROM sourceListenerConfig GROUP BY 1,2 ORDER BY count(*) DESC
            """))
        report.sections.append(try db.table("Graph Subscriptions",[
            Column("View"),Column("Schedule"),Column("Conditions",privateValue:true)
        ], """
            SELECT c.name,s.schedule,CAST(s.config AS TEXT) FROM sourceListenerConfig s
            JOIN viewConfigRecord c ON c.id=s.viewOrderedId
            WHERE s.sourceType='knowledgeGraph' ORDER BY c.name LIMIT 200
            """))
        report.sections.append(try db.table("Materialized Tables",[
            Column("View"),Column("Table"),Column("File"),Column("Stream")
        ], """
            SELECT c.name,t.tableName,c.artifactPath,c.writeToStream
            FROM viewTables t JOIN viewConfigRecord c ON c.id=t.viewOrderedId ORDER BY c.artifactPath,c.name,t.tableName
            """))
        report.sections.append(try db.table("View State",[
            Column("View"),Column("Tables Created"),Column("Bookmark"),Column("Error")
        ], """
            SELECT c.name,s.tablesCreated,s.bookmark IS NOT NULL,length(coalesce(s.errorMessage,''))>0
            FROM viewConfigRecord c LEFT JOIN viewState s ON s.viewOrderedId=c.id ORDER BY c.name
            """))
        report.sections.append(try db.table("Source Availability",[
            Column("Type"),Column("Total"),Column("Available"),Column("Update Modes")
        ], """
            SELECT sourceType,count(*),sum(available),count(DISTINCT updateType)
            FROM sourceState GROUP BY sourceType ORDER BY count(*) DESC
            """))
        report.sections.append(try db.table("Subscription Updates", [Column("Month"),Column("Subscriptions")], """
            SELECT strftime('%Y-%m',sourceUpdatedTimestamp+978307200,'unixepoch'),count(*)
            FROM sourceListenerState WHERE sourceUpdatedTimestamp>0 GROUP BY 1 ORDER BY 1
            """, style: .series))
        report.sections.append(try db.table("Stream Outputs", [
            Column("View"),Column("Type"),Column("File"),Column("Table"),Column("Target",privateValue:true)
        ], """
            SELECT name,artifactType,artifactPath,artifactTable,target FROM viewConfigRecord
            WHERE writeToStream=1 ORDER BY name
            """))
        report.sections.append(try inventories(source))
        report.sections += try ParityReports.subscriptionDetails(source, views: db)
        report.sections += try ParityReports.storageDetails(source,views:db)
        if let kv = try? LocalStore.keyValue.open(source) {
            let fields = try kv.columns(in:"keyvalue")
            let domain = fields["domain"] == nil ? "'General'" : "domain"
            report.sections.append(try kv.table("Key-Value Record Sizes",
                [Column("Domain"),Column("Keys"),Column("Bytes"),Column("Binary Plists")], """
                SELECT \(domain),count(*),sum(length(value)),sum(substr(hex(value),1,12)='62706C697374')
                FROM keyvalue GROUP BY 1 ORDER BY count(*) DESC LIMIT 180
                """, note:"The table summarizes keys and sizes. Values remain in the database."))
        }
        return report
    }

    private static func inventories(_ source: GraphSource) throws -> ReportSection {
        let columns = [Column("File"),Column("Tables"),Column("Bytes"),Column("Build")]
        var rows: [[Cell]] = []
        if source == .demo {
            for store in [LocalStore.graph,.views,.global,.keyValue,.internalViews] {
                let count = try store.open(source).count("SELECT count(*) FROM sqlite_schema WHERE type='table'")
                rows.append([.text(store.rawValue),.integer(count),.empty,.text("Demo")])
            }
        } else if let graph = source.databaseURL {
            let root = graph.deletingLastPathComponent().resolvingSymlinksInPath()
            let immediate = (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey])) ?? []
            let artifacts = root.appending(path:"Artifacts",directoryHint:.isDirectory)
            let enumerator = FileManager.default.enumerator(at:artifacts,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey],
                options:[.skipsHiddenFiles,.skipsPackageDescendants])
            var files = immediate
            if let enumerator {
                for case let file as URL in enumerator.prefix(1_000) { files.append(file) }
            }
            for file in files.sorted(by:{ $0.path < $1.path }) where file.pathExtension == "db" {
                try Task.checkCancellation()
                guard rows.count < 100 else { break }
                guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                      let values = try? file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]),
                      values.isRegularFile == true else { continue }
                let count = try? SQLiteDatabase(url:file).count("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                rows.append([.text(String(file.path.dropFirst(root.path.count+1))),count.map(Cell.integer) ?? .empty,
                             values.fileSize.map { .integer(Int64($0)) } ?? .empty,
                             .text(file.lastPathComponent.contains("-fullRebuild") ? "Intermediate" : "Primary")])
            }
        }
        return ReportSection("Local SQLite Stores",columns,rows,note:"Up to 100 files in the graph and Artifacts directories.")
    }
}
