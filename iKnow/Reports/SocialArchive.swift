import Foundation

extension ParityReports {
    static func archiveNetwork(_ graph: GraphAccess) throws -> SocialIndex.Layer {
        let stable = try graph.knownNames()
        let events = try graph.names(layer:.event).merging(graph.names(layer:.expiredEvent)) { active,_ in active }
        var nodes: [String:SocialIndex.Node] = [:]
        var edges: [SocialIndex.Edge] = []
        var touched: Set<String> = []
        if graph.layers.contains(.expiredStable) {
            var calendar: [String:[GraphTarget]] = [:]
            for layer in [GraphLayer.event,.expiredEvent] where graph.layers.contains(layer) {
                let rows = try graph.db.cells("""
                    SELECT DISTINCT subject,object FROM \(layer.rawValue) WHERE predicate='PS102'
                    AND (object GLOB 'ekEvent:*' OR object GLOB 'sgEvent:*')
                    """)
                for row in rows {
                    if let id = row[0].integer, let token = row[1].text {
                        if !calendar[token,default:[]].contains(where: { $0.id == id }) {
                            calendar[token,default:[]].append(GraphTarget(id:id,layer:layer))
                        }
                    }
                }
            }
            let withdrawn = try graph.db.cells("""
                SELECT DISTINCT subject,object FROM expired_stable_graph WHERE predicate='PS102'
                AND (object GLOB 'ekEvent:*' OR object GLOB 'sgEvent:*')
                """)
            let retained: Set<[Cell]>
            if graph.layers.contains(.stable) {
                retained = Set(try graph.db.cells("""
                    SELECT DISTINCT subject,object FROM stable_graph WHERE predicate='PS102'
                    AND (object GLOB 'ekEvent:*' OR object GLOB 'sgEvent:*')
                    """))
            } else { retained = [] }
            for row in withdrawn where !retained.contains(row) {
                guard let id = row[0].integer, let token = row[1].text else { continue }
                for match in calendar[token,default:[]] where match.id != id {
                    let first = "entity-\(id)"
                    let second = "event-\(match.id)"
                    touched.formUnion([first,second])
                    nodes[first] = .init(id:first,title:stable[id] ?? "ID \(id)",symbol:"person.fill",
                        target:.init(id:id,layer:.expiredStable),isPerson:true)
                    nodes[second] = .init(id:second,title:events[match.id] ?? "ID \(match.id)",symbol:"calendar",
                        target:match,isPerson:false)
                    edges.append(.init(first:first,second:second,label:"Retracted Calendar Reference",weight:nil,archived:true))
                }
            }
        }
        for layer in [GraphLayer.expiredStable,.expiredEvent,.stable,.event] where graph.layers.contains(layer) {
            let archived = layer == .expiredStable || layer == .expiredEvent
            let event = layer == .event || layer == .expiredEvent
            let live: GraphLayer = event ? .event : .stable
            let withdrawnFilter = archived && graph.layers.contains(live) ? """
                AND NOT EXISTS(SELECT 1 FROM \(live.rawValue) a WHERE a.subject=e.subject
                    AND a.predicate=e.predicate AND a.object=e.object)
                """ : ""
            let socialFilter = archived ? "" : "AND predicate IN ('PS753','PS500','PS232','PS578','PS580','demo_friend')"
            let data = try graph.db.cells("""
                SELECT DISTINCT subject,predicate,relationshipPredicate,object
                FROM \(layer.rawValue) e WHERE object GLOB 'md:*'
                \(withdrawnFilter) \(socialFilter)
                ORDER BY subject,predicate,relationshipPredicate,object
                """)
            for row in data {
                guard let left = row[0].integer, let right = GraphAccess.reference(row[3].text), left != right else { continue }
                let first = event ? "event-\(left)" : "entity-\(left)"
                let second = "entity-\(right)"
                if archived { touched.formUnion([first,second]) }
                guard archived || touched.contains(first) || touched.contains(second) else { continue }
                let kind = graph.vocabulary.predicate(row[1].text ?? "")
                edges.append(.init(first:first,second:second,label:kind,weight:nil,archived:archived,
                                   evidenceKey:row[2].text ?? ""))
                let name = event ? events[left] : stable[left]
                nodes[first] = .init(id:first,title:name ?? "ID \(left)",symbol:event ? "calendar" : "person.fill",
                                     target:.init(id:left,layer:layer),isPerson:!event)
                if nodes[second] == nil {
                    nodes[second] = .init(id:second,title:stable[right] ?? "ID \(right)",symbol:"person.fill",
                                          target:.init(id:right),isPerson:true)
                }
            }
        }
        var seen: Set<String> = []
        let unique = edges.filter { seen.insert($0.id).inserted }
        return .init(id:.archive,nodes:nodes.values.sorted { $0.id < $1.id },edges:unique)
    }

    static func chatMembers(_ source: GraphSource, _ db: SQLiteDatabase, names: [Int64:String]) throws -> ReportSection? {
        guard let handles = try? LocalStore.internalViews.open(source).cells("SELECT handle,id FROM handle_id"),
              let members = try? db.cells("""
                SELECT DISTINCT g.rowid,
                       CASE WHEN json_valid(g.fields) THEN json_extract(g.fields,'$.name') END,p.id
                FROM entities g
                JOIN interactionEntities a ON a.entityRowid=g.rowid
                JOIN interactionEntities b ON b.interactionRowid=a.interactionRowid
                JOIN entities p ON p.rowid=b.entityRowid AND p.type='PersonHandle'
                WHERE g.type='MessageGroup' AND p.id IS NOT NULL
                ORDER BY g.rowid,p.id
                """) else { return nil }
        var byHandle: [String:Set<Int64>] = [:]
        for row in handles {
            if let handle = row[0].text, let id = row[1].integer { byHandle[handle,default:[]].insert(id) }
        }
        var rows: [[Cell]] = []
        var targets: [GraphTarget?] = []
        for row in members {
            guard let id = row[0].integer, let handle = row[2].text else { continue }
            let chat = row[1].text ?? "Chat \(id)"
            let matched = byHandle[handle,default:[]].sorted()
            for match in matched {
                rows.append([.text(chat),.text(handle),GraphAccess.label(match,names)])
                targets.append(.init(id:match))
            }
            if matched.isEmpty {
                rows.append([.text(chat),.text(handle),.empty])
                targets.append(nil)
            }
        }
        return ReportSection("Chat Participants by Address Index", [
            Column("Chat",privateValue:true),Column("Address",privateValue:true),Column("Entity",privateValue:true)
        ],rows,note:"Matching by handle_id retains every match for an address.",targets:targets)
    }
}
