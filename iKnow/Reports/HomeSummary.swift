import Foundation

struct HomeEntry: Identifiable, Sendable {
    let id: String
    let title: String
    var subtitle = ""
    var value = ""
    var target: GraphTarget?
}

struct HomeCard: Identifiable, Sendable {
    let page: Page
    let value: Cell
    let detail: String
    var rows: [HomeEntry] = []
    var faceIndex: FaceIndex?
    var id: Page { page }
}

extension AnalysisRepository {
    @concurrent
    static func home(_ source: GraphSource) async throws -> [HomeCard] {
        try source.withScope {
            let graph = try? GraphAccess(source)
            let names = (try? graph?.knownNames()) ?? [:]
            let owner = try? graph?.owner()
            let photos = try? PhotosReport.index(source)
            try Task.checkCancellation()
            let family = try? KinshipReport.load(source)
            let events = graph.flatMap { access in
                access.layers.contains(.event) ? try? access.upcomingEvents() : nil
            }
            let cards: [HomeCard] = [
                HomeCard(page:.faces,value:photos.map { .integer(Int64($0.clusters.filter { $0.faces > 0 }.count)) } ?? .empty,
                         detail:"Face clusters in photos",faceIndex:photos),
                familyCard(family, graph:graph, names:names),
                contactsCard(graph, names:names, owner:owner),
                (try? CommunicationsReport.home(source)) ?? HomeCard(page:.communications,value:.empty,detail:"Communication records"),
                groupsCard(graph, source:source, names:names),
                calendarCard(events ?? [] , available:events != nil),
                HomeCard(page:.store,value:(try? graph?.db.count("SELECT count(*) FROM stable_graph")).map(Cell.integer) ?? .empty,
                         detail:"Records in the main graph")
            ]
            try Task.checkCancellation()
            return cards
        }
    }

    @concurrent
    static func homeSocial(_ source: GraphSource) async throws -> SocialIndex? {
        try source.withScope {
            let graph = try GraphAccess(source)
            return try DerivedReports.social(graph, source).social
        }
    }

    private static func familyCard(_ report: Report?, graph: GraphAccess?, names: [Int64:String]) -> HomeCard {
        let claims = report?.sections.first { $0.title == KinshipReport.claimsTitle }
        var labels: [Int64:[String]] = [:]
        var order: [Int64] = []
        if let claims {
            for (row,target) in zip(claims.rows,claims.targets) {
                guard let target else { continue }
                if labels[target.id] == nil { order.append(target.id) }
                labels[target.id,default:[]].append(row[1].label + " " + row[2].label)
            }
        }
        var rows = order.prefix(8).map { id in
            HomeEntry(id:String(id),title:names[id] ?? "ID \(id)",
                      subtitle:labels[id,default:[]].joined(separator:" · "),target:GraphTarget(id:id))
        }
        if let convergence = report?.sections.first(where:{ $0.title == "Corroborating Features" }) {
            let flags = zip(convergence.rows,convergence.targets).compactMap { row,target -> (Int64,Int)? in
                guard let id = target?.id else { return nil }
                let count = row.dropFirst(3).filter { $0.text == "Yes" || $0.text == "Archive" }.count
                return count > 0 ? (id,count) : nil
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            rows += flags.prefix(4).map { id,count in
                HomeEntry(id:"checks-\(id)",title:names[id] ?? "ID \(id)",
                          subtitle:"Corroborating features",value:count.formatted(.number.locale(.iKnow)),target:GraphTarget(id:id))
            }
        }
        let people = report?.sections.first { $0.title == "Score Matrix" }
        let count = report?.metrics.first { $0.title == "People Scored" }?.value
        let metric: Cell
        if let count { metric = .text(count) }
        else if let people { metric = .integer(Int64(people.rows.count)) }
        else { metric = .empty }
        if let graph, let groups = try? graph.members(layer:.stable,predicate:"PS753",facet:"PS566"),
           let owner = try? graph.owner() {
            rows += groups.filter { $0.value.contains(owner) }.sorted { $0.key < $1.key }.map { id,members in
                HomeEntry(id:"group-\(id)",title:names[id] ?? "Group",subtitle:members.sorted().compactMap { names[$0] }.joined(separator:", "),
                          value:"\(members.count)",target:GraphTarget(id:id))
            }
        }
        return HomeCard(page:.kinship,value:metric,detail:"People with kinship scores",rows:rows)
    }

    private static func contactsCard(_ graph: GraphAccess?, names: [Int64:String], owner: Int64?) -> HomeCard {
        guard let graph, graph.layers.contains(.stable),
              let values = try? graph.db.cells("""
                  SELECT DISTINCT subject,relationshipPredicate,object FROM stable_graph
                  WHERE predicate='PS520' AND relationshipPredicate IN ('PS406','PS407') AND length(object)>0
                  ORDER BY subject,relationshipPredicate,object
                  """) else { return HomeCard(page:.identity,value:.empty,detail:"Phone numbers and addresses in the graph") }
        let sorted = values.sorted { lhs,rhs in
            if (lhs[0].integer == owner) != (rhs[0].integer == owner) { return lhs[0].integer == owner }
            return (lhs[0].integer ?? 0,lhs[1].label,lhs[2].label) < (rhs[0].integer ?? 0,rhs[1].label,rhs[2].label)
        }
        let people = Set(values.compactMap { $0[0].integer })
        let phones = values.filter { $0[1].text == "PS407" }.count
        let rows: [HomeEntry] = sorted.prefix(12).enumerated().compactMap { index,row in
            guard let id = row[0].integer else { return nil }
            return HomeEntry(id:String(index),title:names[id] ?? "ID \(id)",
                             subtitle:row[1].text == "PS407" ? "Phone" : "Email",
                             value:row[2].label,target:GraphTarget(id:id))
        }
        return HomeCard(page:.identity,value:.integer(Int64(values.count)),
                        detail:"\(people.count) people · \(phones) phone numbers · \(values.count-phones) addresses",rows:rows)
    }

    private static func groupsCard(_ graph: GraphAccess?, source: GraphSource, names: [Int64:String]) -> HomeCard {
        let groups = try? graph?.members(layer:.stable,predicate:"PS753",facet:"PS566")
        let employers = try? graph?.members(layer:.stable,predicate:"PS500",facet:"PS45")
        var employees: [Int64:Set<Int64>] = [:]
        for (person,organisations) in employers ?? [:] {
            for organisation in organisations { employees[organisation,default:[]].insert(person) }
        }
        var rows: [HomeEntry] = (groups ?? [:]).sorted { $0.key < $1.key }.prefix(6).map { id,members in
            HomeEntry(id:"group-\(id)",title:names[id] ?? "Group",
                      subtitle:members.sorted().compactMap { names[$0] }.joined(separator:", "),
                      value:"\(members.count)",target:GraphTarget(id:id))
        }
        rows += employees.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.prefix(4).map { id,members in
            HomeEntry(id:"org-\(id)",title:names[id] ?? "Organization",subtitle:"Employer",
                      value:"\(members.count)",target:GraphTarget(id:id))
        }
        let chats = try? LocalStore.interactions.open(source).cells("""
            SELECT e.rowid, CASE WHEN json_valid(e.fields) THEN json_extract(e.fields,'$.name') END,
                   count(DISTINCT i.rowid),date(max(i.startDate)+978307200,'unixepoch')
            FROM entities e JOIN interactionEntities l ON l.entityRowid=e.rowid
            JOIN interactions i ON i.rowid=l.interactionRowid WHERE e.type='MessageGroup'
            GROUP BY e.rowid ORDER BY 3 DESC,e.rowid LIMIT 6
            """)
        rows += (chats ?? []).map { row in
            HomeEntry(id:"chat-"+row[0].label,title:row[1].text ?? "Chat",subtitle:"Group chat · "+row[3].label,value:row[2].label)
        }
        return HomeCard(page:.social,value:groups.map { .integer(Int64($0.count)) } ?? .empty,detail:"Groups in the main graph",rows:rows)
    }

    private static func calendarCard(_ events: [UpcomingEvent], available: Bool) -> HomeCard {
        let rows = events.prefix(8).map { event in
            HomeEntry(id:event.id,title:event.title,subtitle:event.guests.prefix(4).joined(separator:", "),
                      value:event.clock,target:GraphTarget(id:event.subject,layer:.event))
        }
        let links = events.filter { $0.conferenceLinks > 0 }.count
        return HomeCard(page:.calendar,value:available ? .integer(Int64(events.count)) : .empty,
                        detail:"After the last graph record · \(links) with a conference link",rows:rows)
    }
}
