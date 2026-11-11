import CryptoKit
import Foundation

enum GraphReports {
    static func load(_ page: Page, source: GraphSource) throws -> Report {
        if page == .consumers { return try DerivedReports.consumers(source) }
        let graph = try GraphAccess(source)
        return switch page {
        case .store: try overview(graph)
        case .social: try DerivedReports.social(graph, source)
        case .certainty: try certainty(graph)
        case .calendar: try calendar(graph, source)
        case .identity: try identity(graph, source)
        case .retractions: try retractions(graph)
        case .apps: try DerivedReports.apps(graph, source)
        default: Report()
        }
    }

    private static let namespaces = [
        "md", "cnContact", "phPerson", "ekEvent", "sgEvent", "sgContact", "inPerson",
        "lsBundleRecord", "faFamilyCircle", "association", "tel", "mailto", "https", "http"
    ]

    private static func overview(_ graph: GraphAccess) throws -> Report {
        var totals: [[Cell]] = []
        var classes: [[Cell]] = []
        var namespaces: [[Cell]] = []
        var live: Int64 = 0
        var expired: Int64 = 0
        for layer in graph.layers {
            let count = try graph.db.cells("""
                SELECT count(*),count(DISTINCT subject),sum(confidence < 1.0),
                       count(DISTINCT CASE WHEN relationshipId<>0 THEN relationshipId END)
                FROM \(layer.rawValue)
                """).first ?? []
            totals.append([.text(layer.title)] + count)
            let rows = count.first?.integer ?? 0
            if layer == .stable || layer == .event { live += rows } else { expired += rows }
            let census = try graph.db.cells("""
                SELECT object,count(DISTINCT subject) FROM \(layer.rawValue)
                WHERE predicate='PS1' AND relationshipId=0 GROUP BY object
                ORDER BY count(DISTINCT subject) DESC,object
                """)
            classes += census.map { [.text(layer.title), .text(graph.vocabulary.kind($0[0].text)), $0[0], $0[1]] }
            namespaces += try namespaceRows(graph, layer: layer)
        }
        var report = Report(metrics: [
            Metric("Active Rows", live), Metric("Archived", expired), Metric("Layers", Int64(graph.layers.count))
        ])
        report.sections = [
            ReportSection("SQLite Layers", [Column("Layer"),Column("Rows"),Column("Entities"),Column("Rows with Confidence < 1"),Column("Relationship IDs")], totals),
            ReportSection("Entity Classes", [Column("Layer"),Column("Class"),Column("Code"),Column("Entities")], classes),
            ReportSection("Graph Reference Namespaces", [Column("Layer"),Column("Namespace"),Column("Rows"),Column("Values"),Column("Entities")], namespaces)
        ]
        report.sections.append(try graph.db.table("Graph State", [Column("Key"),Column("Value", privateValue: true)], """
            SELECT key,value FROM graph_state ORDER BY key
            """, note: "Apple internal keys. Timestamps may be relative to the 2001 epoch."))
        if graph.layers.contains(.stable) {
            let identities = try ParityReports.identityPopulation(graph)
            report.sections.append(identities.section)
            let owner = try graph.owner()
            let names = try graph.knownNames()
            let peer = identities.people.filter { $0.id != owner }.max {
                ($0.spaces.count, $0.facts, $0.id) < ($1.spaces.count, $1.facts, $1.id)
            }?.id
            let examples = [owner.map { ("Owner", $0) }, peer.map { ("Connected Person", $0) }].compactMap { $0 }
            report.sections.append(ReportSection("Two Examples from the Graph",
                [Column("Role"),Column("Name",privateValue:true),Column("Namespace References"),Column("Facts")],
                examples.map { role,id in
                    let person = identities.people.first { $0.id == id }
                    return [.text(role),GraphAccess.label(id,names),.integer(Int64(person?.spaces.count ?? 0)),.integer(person?.facts ?? 0)]
                }, targets:examples.map { GraphTarget(id:$0.1) }))
        }
        return report
    }

    private static func namespaceRows(_ graph: GraphAccess, layer: GraphLayer) throws -> [[Cell]] {
        let placeholders = namespaces.map { _ in "?" }.joined(separator: ",")
        let rows = try graph.db.cells("""
            SELECT substr(object,1,instr(object,':')-1) AS namespace,
                count(*),count(DISTINCT object),count(DISTINCT subject)
            FROM \(layer.rawValue) WHERE instr(object,':')>0 AND namespace IN (\(placeholders))
            GROUP BY 1 ORDER BY count(*) DESC,1
            """, namespaces.map(SQLiteDatabase.Parameter.text))
        return rows.map { [.text(layer.title)] + $0 }
    }

    private static func certainty(_ graph: GraphAccess) throws -> Report {
        var distribution: [[Cell]] = []
        var predicates: [[Cell]] = []
        var sources: [[Cell]] = []
        var combinations: [[Cell]] = []
        var sourcesLedger: [[Cell]] = []
        let bits = Evidence.sourceBits
        for layer in graph.layers {
            distribution += try graph.db.cells("""
                SELECT confidence,count(*) FROM \(layer.rawValue)
                GROUP BY confidence ORDER BY confidence DESC LIMIT 200
                """).map { [.text(layer.title)] + $0 }
            let table = try graph.db.cells("""
                SELECT predicate,count(*),sum(confidence=1),sum(confidence<1),avg(confidence)
                FROM \(layer.rawValue) GROUP BY predicate ORDER BY count(*) DESC,predicate LIMIT 120
                """)
            predicates += table.map { [.text(layer.title), .text(graph.vocabulary.predicate($0[0].text ?? ""))] + $0 }
            for (bit, name) in bits {
                let stats = try graph.db.cells("""
                    SELECT count(*),avg(confidence),min(confidence),max(confidence)
                    FROM \(layer.rawValue) WHERE sources & ? <> 0
                    """, [.integer(Int64(1)<<bit)]).first ?? []
                if (stats.first?.integer ?? 0) > 0 { sources.append([.text(layer.title), .text(name)] + stats) }
            }
            combinations += try graph.db.cells("""
                SELECT printf('0x%X',sources),count(*),avg(confidence)
                FROM \(layer.rawValue) GROUP BY sources ORDER BY count(*) DESC LIMIT 120
                """).map { [.text(layer.title)] + $0 }
            sourcesLedger += try graph.db.cells("""
                SELECT predicate,count(*),sum(coalesce(sourceDuplicates,'')<>''),sum(
                    CASE WHEN coalesce(sourceDuplicates,'')='' THEN 0 ELSE
                    1+length(sourceDuplicates)-length(replace(sourceDuplicates,char(30),'')) END)
                FROM \(layer.rawValue) GROUP BY predicate ORDER BY count(*) DESC LIMIT 120
                """).map { [.text(layer.title), .text(graph.vocabulary.predicate($0[0].text ?? ""))] + Array($0.dropFirst()) }
        }
        let examples = try ParityReports.confidenceExamples(graph)
        let provenance = try graph.provenanceEvidence()
        let layerColumn = Column("Layer",format:.layer)
        let average = Column("Average",format:.score)
        return Report(metrics: [Metric("Confidence Groups", Int64(distribution.count)),Metric("Source Combinations", Int64(combinations.count))],
            sections: [
                ReportSection("Confidence Distribution", [layerColumn,Column("Confidence",format:.score),Column("Rows")], distribution,
                    note: "Graph confidence can reflect the source of a record."),
                ReportSection("Predicates and Scores", [layerColumn,Column("Predicate"),Column("Code",format:.code),Column("Rows"),Column("= 1"),Column("< 1"),average], predicates),
                ReportSection("Individual Sources", [layerColumn,Column("Source"),Column("Rows"),average,Column("Minimum",format:.score),Column("Maximum",format:.score)], sources),
                ReportSection("Source Combinations", [layerColumn,Column("Mask",format:.code),Column("Rows"),average], combinations),
                ReportSection("Records in sourceDuplicates", [layerColumn,Column("Predicate"),Column("Rows"),Column("With a Source"),Column("References")], sourcesLedger)
            ] + provenance + examples)
    }

    private static func retractions(_ graph: GraphAccess) throws -> Report {
        var fates: [[Cell]] = []
        var dates: [[Cell]] = []
        var records: [[Cell]] = []
        var predicates: [[Cell]] = []
        var survival: [[Cell]] = []
        var retained: [[Cell]] = []
        var targets: [GraphTarget?] = []
        for (archive, live) in [(GraphLayer.expiredStable, GraphLayer.stable),(.expiredEvent,.event)]
        where graph.layers.contains(archive) {
            let active = live.rawValue
            let fate: String
            if graph.layers.contains(live) {
                fate = """
                    CASE WHEN EXISTS(SELECT 1 FROM \(active) l WHERE l.subject=e.subject AND l.predicate=e.predicate
                      AND l.relationshipPredicate IS e.relationshipPredicate AND l.object IS e.object) THEN 'Reasserted'
                      WHEN EXISTS(SELECT 1 FROM \(active) l WHERE l.subject=e.subject AND l.predicate=e.predicate) THEN 'Superseded'
                      WHEN EXISTS(SELECT 1 FROM \(active) l WHERE l.subject=e.subject) THEN 'Retracted'
                      ELSE 'Entity Disappeared' END
                    """
            } else {
                fate = "'Active Layer Unavailable'"
            }
            let table = archive.rawValue
            fates += try graph.db.cells("""
                SELECT \(fate) AS fate,count(*) FROM \(table) e GROUP BY fate ORDER BY count(*) DESC
                """).map { [.text(archive.title)] + $0 }
            dates += try graph.db.cells("""
                SELECT date(timestamp+978307200,'unixepoch','localtime'),count(*)
                FROM \(table) WHERE timestamp IS NOT NULL GROUP BY 1 ORDER BY 1 DESC LIMIT 100
                """).map { [.text(archive.title)] + $0 }
            predicates += try graph.db.cells("""
                SELECT predicate,\(fate) AS fate,count(*) FROM \(table) e
                GROUP BY predicate,fate ORDER BY count(*) DESC LIMIT 150
                """).map { [.text(archive.title), .text(graph.vocabulary.predicate($0[0].text ?? "")), $0[1], $0[2]] }
            let recent = try graph.db.cells("""
                SELECT CAST(subject AS TEXT),predicate,relationshipPredicate,object,confidence,
                    datetime(timestamp+978307200,'unixepoch','localtime'),\(fate)
                FROM \(table) e ORDER BY timestamp DESC,subject LIMIT 150
                """)
            records += recent.map { [.text(archive.title)] + $0 }
            targets += recent.map { row in row[0].integer.map { GraphTarget(id: $0, layer: archive) } }
            let survived = graph.layers.contains(live)
                ? "EXISTS(SELECT 1 FROM \(active) l WHERE l.subject=e.subject)" : "NULL"
            survival += try graph.db.cells("""
                SELECT count(DISTINCT e.subject),count(DISTINCT CASE WHEN \(survived) THEN e.subject END),
                       count(DISTINCT CASE WHEN NOT (\(survived)) THEN e.subject END)
                FROM \(table) e
                """).map { [.text(archive.title)] + $0 }
            retained += try graph.db.cells("""
                SELECT count(*),sum(confidence=0),sum(coalesce(sourceDuplicates,'')=''),sum(coalesce(sources,0)=0)
                FROM \(table)
                """).map { [.text(archive.title)] + $0 }
        }
        let total = fates.reduce(Int64(0)) { $0 + ($1.last?.integer ?? 0) }
        let archive = try ParityReports.archiveNetwork(graph)
        var report = Report(metrics: [Metric("Archived Rows", total)], sections: [
            ReportSection("Record Outcomes", [Column("Layer"),Column("Status"),Column("Rows")], fates,
                note: "Status is determined by comparing against the active table. The archive retains the original row timestamp."),
            ReportSection("Archived Row Timestamps", [Column("Layer"),Column("Day"),Column("Rows")], dates),
            ReportSection("Retracted Predicates", [Column("Layer"),Column("Predicate"),Column("Status"),Column("Rows")], predicates),
            ReportSection("Archived Rows", [Column("Layer"),Column("ID",privateValue:true),Column("Predicate"),Column("Field"),
                Column("Value",privateValue:true),Column("Confidence"),Column("Recorded"),Column("Status")], records,
                note: "Up to 150 rows per layer.", targets: targets),
            ReportSection("Entities After Retraction", [
                Column("Layer"),Column("Total"),Column("Has Active Rows"),Column("No Active Rows")
            ], survival, note: "Counts refer to the corresponding active layer."),
            ReportSection("Archived Confidence and Provenance", [
                Column("Layer"),Column("Total"),Column("Zero Confidence"),Column("No Source References"),Column("No Source Mask")
            ], retained)
        ], social: SocialIndex(layers:[archive]))
        if graph.layers.contains(.expiredEvent) {
            report.sections.append(try graph.db.table("Retracted Event Dates", [
                Column("Month"),Column("Events"),Column("Dates")
            ], """
                WITH dates AS (
                    SELECT subject,CASE WHEN json_valid(object) THEN
                        printf('%04d-%02d',json_extract(object,'$.year'),json_extract(object,'$.month')) END month
                    FROM expired_event_graph WHERE relationshipPredicate='PS29'
                )
                SELECT month,count(DISTINCT subject),count(*) FROM dates WHERE month IS NOT NULL AND month<>'0000-00'
                GROUP BY month ORDER BY month
                """, style: .series))
        }
        return report
    }

    private static func calendar(_ graph: GraphAccess, _ source: GraphSource) throws -> Report {
        guard graph.layers.contains(.event) else { throw GraphFailure.schema }
        let count = try graph.db.count("SELECT count(DISTINCT subject) FROM event_graph")
        let participants = try graph.members(layer: .event, predicate: "PS232", facet: "PS143")
        let names = try graph.knownNames()
        let events = try graph.names(layer: .event)
        let owner = try graph.owner()
        let organizers = try graph.members(layer: .event, predicate: "PS578", facet: "PS143")
        let senders = try graph.members(layer: .event, predicate: "PS580", facet: "PS143")
        var contactCounts: [Int64: Int64] = [:]
        for people in participants.values {
            for id in people where id != owner { contactCounts[id, default: 0] += 1 }
        }
        var report = Report(metrics: [
            Metric("Event Entities", count), Metric("With Participants", Int64(participants.count)),
            Metric("Participants Excluding the Owner", Int64(contactCounts.count))
        ])
        report.sections.append(try graph.db.table("Schedule", [
            Column("Starts"), Column("Time Zone", privateValue:true), Column("Event", privateValue:true),
            Column("Place", privateValue:true), Column("ID", privateValue:true)
        ], """
            SELECT CASE WHEN json_extract(s.object,'$.hour') IS NULL
                   THEN printf('%04d-%02d-%02d',json_extract(s.object,'$.year'),
                       json_extract(s.object,'$.month'),json_extract(s.object,'$.day'))
                   ELSE printf('%04d-%02d-%02d %02d:%02d',json_extract(s.object,'$.year'),json_extract(s.object,'$.month'),
                       json_extract(s.object,'$.day'),json_extract(s.object,'$.hour'),coalesce(json_extract(s.object,'$.minute'),0))
                   END AS starts,
                   json_extract(s.object,'$.timeZone.identifier'),
                   (SELECT object FROM event_graph n WHERE n.subject=s.subject AND n.predicate='PS33'
                    ORDER BY confidence DESC,object LIMIT 1),
                   (SELECT object FROM event_graph v WHERE v.subject=s.subject AND v.predicate='PS225'
                    AND v.relationshipPredicate='PS733' ORDER BY confidence DESC,object LIMIT 1),
                   CAST(s.subject AS TEXT)
            FROM event_graph s WHERE s.relationshipPredicate='PS29' AND json_valid(s.object)
            AND json_extract(s.object,'$.year') IS NOT NULL
            GROUP BY 1,2,3,4,5 ORDER BY starts DESC LIMIT 250
            """, note: "The latest 250 dates by event time, including future dates. Dates are interpreted from Apple date components."))
        report.sections.append(try graph.db.table("Monthly Calendar",
            [Column("Month"),Column("Events"),Column("All Day")], """
            SELECT printf('%04d-%02d',json_extract(object,'$.year'),json_extract(object,'$.month')),
                   count(DISTINCT subject),count(DISTINCT CASE WHEN json_extract(object,'$.hour') IS NULL THEN subject END)
            FROM event_graph WHERE relationshipPredicate='PS29' AND json_valid(object)
            AND json_extract(object,'$.year') IS NOT NULL GROUP BY 1 ORDER BY 1
            """, style:.series))
        report.sections.append(try graph.db.table("Event Classes and Sources",
            [Column("Class"),Column("Mask"),Column("Entities")], """
            SELECT object,printf('0x%X',sources),count(DISTINCT subject) FROM event_graph
            WHERE predicate='PS1' AND relationshipId=0 GROUP BY 1,2 ORDER BY count(DISTINCT subject) DESC
            """))
        report.sections.append(try graph.db.table("Event Fields",
            [Column("Predicate"),Column("Field"),Column("Rows"),Column("Events"),Column("Average Confidence")], """
            SELECT predicate,relationshipPredicate,count(*),count(DISTINCT subject),avg(confidence)
            FROM event_graph GROUP BY 1,2 ORDER BY count(*) DESC LIMIT 150
            """))
        let upcoming = try graph.upcomingEvents()
        report.sections.append(ReportSection("Events After the Last Graph Record", [
            Column("Starts",privateValue:true),Column("Event",privateValue:true),
            Column("Invitees",privateValue:true),Column("Participants"),Column("Owner Included"),
            Column("Minutes"),Column("References"),Column("Time Zone",privateValue:true)
        ], upcoming.map { event in [
            .text(event.clock),.text(event.title),.text(event.guests.joined(separator:", ")),
            .integer(Int64(event.attendeeCount)),.text(event.includesOwner ? "Yes" : "—"),
            event.duration.map(Cell.integer) ?? .empty,.integer(event.conferenceLinks),
            event.timeZone.map(Cell.text) ?? .empty
        ]}, targets:upcoming.map { GraphTarget(id:$0.subject,layer:.event) }))
        report.sections += try ParityReports.calendar(graph, owner: owner)
        let person = Column("Participant",privateValue:true)
        report.sections.append(ReportSection("Event Participants by Frequency", [person,Column("Events")],
            contactCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(150)
                .map { [GraphAccess.label($0.key,names), .integer($0.value)] }))
        let roles = [("Participants",participants),("Organizers",organizers),("Senders",senders)]
        for (role, members) in roles {
            let rows = members.sorted { $0.key < $1.key }.prefix(200).map { event, people in
                [GraphAccess.label(event, events), .text(people.sorted().map { names[$0] ?? "ID \($0)" }.joined(separator: ", ")), .integer(Int64(people.count))]
            }
            report.sections.append(ReportSection(role,[Column("Event",privateValue:true),Column(role,privateValue:true),Column("Total")], rows))
        }
        report.sections.append(try graph.db.table("Places, Conferences, and Travel",
            [Column("ID",privateValue:true),Column("Field"),Column("Value",privateValue:true)], """
            SELECT CAST(subject AS TEXT),coalesce(nullif(relationshipPredicate,''),predicate),object
            FROM event_graph WHERE predicate IN ('PS225','PS248','PS249','nm_virtualConferenceURL','nm_flightNumber','nm_iataCode')
            OR relationshipPredicate IN ('PS406','PS407')
            ORDER BY timestamp DESC,subject LIMIT 200
            """))
        report.sections += try graph.calendarRhythm()
        report.sections += try graph.travelEvidence()
        if let original = try? LocalStore.calendar.open(source) {
            report.sections += try graph.calendarSourceEvidence(original)
            report.sections.append(try original.table("Calendar Source Database", [
                Column("Records"),Column("Earliest Date"),Column("Latest Date")
            ], """
                SELECT count(*),date(min(start_date)+978307200,'unixepoch','localtime'),
                       date(max(start_date)+978307200,'unixepoch','localtime') FROM CalendarItem
                """))
            let identifiers = try? original.cells("""
                SELECT DISTINCT s.persistent_id || ':' || ci.unique_identifier
                FROM CalendarItem ci JOIN Calendar ca ON ca.ROWID=ci.calendar_id JOIN Store s ON s.ROWID=ca.store_id
                WHERE ci.unique_identifier IS NOT NULL AND s.persistent_id IS NOT NULL
                """)
            if let identifiers {
                let tokens = Set(identifiers.compactMap { $0[0].text.map(digest) })
                let refs = try graph.db.cells("SELECT DISTINCT substr(object,9) FROM event_graph WHERE object GLOB 'ekEvent:*'")
                let references = Set(refs.compactMap { $0[0].text })
                report.sections.append(ReportSection("EventKit Verification", [
                    Column("Graph Tokens"),Column("Source Database Tokens"),Column("Matches")
                ], [[.integer(Int64(references.count)),.integer(Int64(tokens.count)),
                     .integer(Int64(references.intersection(tokens).count))]],
                    note:"Verification uses SHA-256 of the calendar store and record identifiers."))
            }
        }
        return report
    }

    private static func identity(_ graph: GraphAccess, _ source: GraphSource) throws -> Report {
        var all: [[Cell]] = []
        var aggregate: [[Cell]] = []
        var predicates: [[Cell]] = []
        var referenceValues: [String: Set<String>] = [:]
        let names = try graph.knownNames()
        for layer in graph.layers {
            aggregate += try namespaceRows(graph, layer: layer)
            predicates += try graph.db.cells("""
                SELECT predicate,substr(object,1,instr(object,':')-1) AS namespace,count(*),count(DISTINCT subject)
                FROM \(layer.rawValue) WHERE instr(object,':')>0 AND namespace IN ('cnContact','phPerson','ekEvent','sgEvent','sgContact','lsBundleRecord','faFamilyCircle','md')
                GROUP BY 1,2 ORDER BY count(*) DESC LIMIT 150
                """).map { [.text(layer.title),.text(graph.vocabulary.predicate($0[0].text ?? ""))] + Array($0.dropFirst()) }
            let refs = try graph.db.cells("""
                SELECT DISTINCT substr(object,1,instr(object,':')-1) AS namespace,
                       substr(object,instr(object,':')+1)
                FROM \(layer.rawValue) WHERE namespace IN ('cnContact','phPerson','ekEvent','sgEvent','lsBundleRecord')
                """)
            for row in refs {
                if let namespace = row[0].text, let value = row[1].text { referenceValues[namespace, default: []].insert(value) }
            }
            let joins = try graph.db.cells("""
                SELECT subject,predicate,relationshipPredicate,object,confidence
                FROM \(layer.rawValue)
                WHERE predicate IN ('PS102','PS317') OR relationshipPredicate IN ('PS406','PS407') OR object GLOB 'phPerson:*'
                ORDER BY subject,predicate,object LIMIT 200
                """)
            all += joins.compactMap { row in
                guard let id = row[0].integer else { return nil }
                return [.text(layer.title), .text(String(id)), GraphAccess.label(id,names)] + Array(row.dropFirst())
            }
        }

        var checks: [[Cell]] = []
        let photos = try? LocalStore.photos.open(source).cells("SELECT DISTINCT upper(ZPERSONUUID) FROM ZPERSON")
        let faceIDs = photos.map { Set($0.compactMap { $0[0].text }) }
        let faceRefs = referenceValues["phPerson", default: []]
        checks.append([.text("Photos"), .integer(Int64(faceRefs.count)), faceIDs.map { ids in
            .integer(Int64(faceRefs.filter { ids.contains(String($0.split(separator: "/").first ?? "").uppercased()) }.count))
        } ?? .empty])
        let events = try? LocalStore.calendar.open(source).cells("""
            SELECT DISTINCT s.persistent_id || ':' || ci.unique_identifier
            FROM CalendarItem ci JOIN Calendar ca ON ca.ROWID=ci.calendar_id JOIN Store s ON s.ROWID=ca.store_id
            WHERE ci.unique_identifier IS NOT NULL AND s.persistent_id IS NOT NULL
            """)
        let calendarTokens = events.map { Set($0.compactMap { $0[0].text.map(digest) }) }
        let eventRefs = referenceValues["ekEvent", default: []]
        checks.append([.text("Calendar"), .integer(Int64(eventRefs.count)),
                       calendarTokens.map { .integer(Int64(eventRefs.intersection($0).count)) } ?? .empty])
        let contactRefs = referenceValues["cnContact", default: []]
        let contacts = try contactIDs(source, matching: contactRefs)
        checks.append([.text("Contacts"), .integer(Int64(contactRefs.count)),
                       contacts.map { .integer(Int64($0.count)) } ?? .empty])
        let appRefs = referenceValues["lsBundleRecord", default: []]
        let appTokens: Set<String>
        if graph.layers.contains(.stable) {
            appTokens = Set(try graph.db.cells("SELECT DISTINCT object FROM stable_graph WHERE predicate='nm_bundleID'")
                .compactMap { $0[0].text.map(digest) })
        } else { appTokens = [] }
        checks.append([.text("App Catalog"), .integer(Int64(appRefs.count)),
                       .integer(Int64(appRefs.intersection(appTokens).count))])

        var report = Report(metrics: [Metric("External ID Namespaces", Int64(referenceValues.count))], sections: [
            ReportSection("References by Namespace", [Column("Layer"),Column("Namespace"),Column("Rows"),Column("Values"),Column("Entities")], aggregate),
            ReportSection("Verification Against Source Data", [Column("Store"),Column("References"),Column("Matches")], checks,
                note: "A dash means the source database or table is unavailable."),
            ReportSection("Reference Predicates", [Column("Layer"),Column("Predicate"),Column("Namespace"),Column("Rows"),Column("Entities")], predicates),
            ReportSection("References, Addresses, and Phone Numbers", [Column("Layer"),Column("ID",privateValue:true),Column("Entity",privateValue:true),
                Column("Predicate"),Column("Field"),Column("Value",privateValue:true),Column("Confidence")], all, note:"Up to 200 records per layer.")
        ])
        var funnel: [[Cell]] = []
        let resolvedFaces = faceIDs.map { ids in Set(faceRefs.filter {
            ids.contains(String($0.split(separator:"/").first ?? "").uppercased())
        }) }
        let resolved: [String:Set<String>] = [
            "cnContact":contacts, "phPerson":resolvedFaces, "ekEvent":calendarTokens,
            "lsBundleRecord":appTokens
        ].compactMapValues { $0 }
        for layer in graph.layers {
            let data = try graph.db.cells("""
                SELECT DISTINCT subject,substr(object,1,instr(object,':')-1) AS space,
                                substr(object,instr(object,':')+1)
                FROM \(layer.rawValue)
                WHERE space IN ('cnContact','phPerson','ekEvent','sgEvent','sgContact','inPerson','faFamilyCircle','lsBundleRecord')
                """)
            let bySpace = Dictionary(grouping:data,by:{ $0[1].text ?? "" })
            for space in bySpace.keys.sorted() {
                let rows = bySpace[space,default:[]]
                let matched = resolved[space].map { values in rows.filter { values.contains($0[2].text ?? "") } }
                let ids = Set(rows.compactMap { $0[0].integer })
                let named = ids.filter { names[$0] != nil }.count
                let matchedIDs = matched.map { Set($0.compactMap { $0[0].integer }).count }
                funnel.append([.text(layer.title),.text(space),.integer(Int64(Set(rows.compactMap { $0[2].text }).count)),
                    .integer(Int64(ids.count)),.integer(Int64(named)),matchedIDs.map { .integer(Int64($0)) } ?? .empty])
            }
        }
        report.sections.append(ReportSection("Identity Resolution Funnel",[
            Column("Layer"),Column("Namespace"),Column("Distinct References"),Column("Entities"),
            Column("Named"),Column("Resolved Entities")
        ],funnel,note:"The last column shows results for available stores with verifiable identifiers."))
        if graph.layers.contains(.stable) {
            let population = try ParityReports.identityPopulation(graph)
            report.sections.append(population.section)
            report.sections += try ParityReports.contactEvidence(graph, source: source)
            let people = population.people.sorted {
                ($0.spaces.count,$0.facts,$0.id) > ($1.spaces.count,$1.facts,$1.id)
            }
            report.sections.append(ReportSection("Identity Cards", [
                Column("Entity",privateValue:true),Column("Namespaces"),Column("Facts")
            ], people.map {
                [GraphAccess.label($0.id,names),.text($0.spaces.sorted().joined(separator:", ")),.integer($0.facts)]
            }, targets:people.map { GraphTarget(id:$0.id) }))
        }
        if let db = try? LocalStore.internalViews.open(source) {
            report.sections.append(try db.table("Addresses Matched to Entities", [Column("Address",privateValue:true),Column("Entities")], """
                SELECT handle,count(DISTINCT id) FROM handle_id GROUP BY handle ORDER BY count(DISTINCT id) DESC LIMIT 180
                """))
        }
        if let db = try? LocalStore.messages.open(source) {
            report.sections.append(try db.table("Addresses from Messages", [Column("Addresses")], "SELECT count(DISTINCT id) FROM handle"))
        }
        return report
    }

    static func digest(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }

    private static func contactIDs(_ source: GraphSource, matching ids: Set<String>) throws -> Set<String>? {
        if source == .demo { return ids.intersection(["demo-mira:ABPerson", "demo-anya:ABPerson"]) }
        let directory: URL
        switch source {
        case .mac:
            directory = URL(filePath:NSHomeDirectory()).appending(path:"Library/Application Support/AddressBook/Sources")
        case .bundle(let root): directory = root.appending(path:"sources/AddressBook")
        case .file, .demo: return nil
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        else { return nil }
        var matched: Set<String> = []
        var read = false
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(32) {
            try Task.checkCancellation()
            let url = source == .mac ? file.appending(path:"AddressBook-v22.abcddb") : file
            guard url.pathExtension == "abcddb", let db = try? SQLiteDatabase(url:url),
                  let rows = try? db.cells("SELECT ZUNIQUEID,ZLINKID FROM ZABCDRECORD") else { continue }
            read = true
            for value in rows.flatMap({ $0 }).compactMap(\.text) where ids.contains(value) { matched.insert(value) }
        }
        return read ? matched : nil
    }
}
