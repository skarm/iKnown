import Foundation

enum ParityReports {
    struct Identity {
        let id: Int64
        let facts: Int64
        var spaces: Set<String> = []
    }

    static func identityPopulation(_ graph: GraphAccess) throws -> (section: ReportSection, people: [Identity]) {
        let rows = try graph.db.cells("""
            SELECT subject,count(*) FROM stable_graph GROUP BY subject
            HAVING max(predicate='PS1' AND object='SB104')=1
            """)
        var people: [Int64: Identity] = [:]
        for row in rows {
            if let id = row[0].integer { people[id] = Identity(id:id,facts:row[1].integer ?? 0) }
        }
        let references = try graph.db.cells("""
            SELECT DISTINCT subject,substr(object,1,instr(object,':')-1) AS space
            FROM stable_graph
            WHERE predicate IN ('PS102','PS317','nm_hasVisualIdentifier')
            AND space IN ('cnContact','phPerson','sgContact','inPerson','faFamilyCircle')
            """)
        for row in references {
            if let id = row[0].integer, let namespace = row[1].text { people[id]?.spaces.insert(namespace) }
        }
        var counts: [String:Int64] = [:]
        for person in people.values {
            let category = person.spaces.count > 1 ? "Multiple Namespaces" :
                person.spaces.first ?? "No External References"
            counts[category,default:0] += 1
        }
        let data = counts.sorted { ($0.value,$0.key) > ($1.value,$1.key) }.map { [Cell.text($0.key),.integer($0.value)] }
        return (ReportSection("Identity Connectivity",
            [Column("Namespace"),Column("People")],data,style:.bars,
            note:"An isolated identity has no external namespace references in the main graph."),
            people.values.sorted { $0.id < $1.id })
    }

    static func confidenceExamples(_ graph: GraphAccess) throws -> [ReportSection] {
        var rows: [[Cell]] = []
        var targets: [GraphTarget?] = []
        for layer in graph.layers {
            let data = try graph.db.cells("""
                WITH examples AS (
                    SELECT subject,predicate,object,confidence,sources,
                        row_number() OVER(PARTITION BY confidence ORDER BY subject,predicate,object) rank
                    FROM \(layer.rawValue) WHERE confidence IS NOT NULL
                )
                SELECT confidence,subject,predicate,object,printf('0x%X',sources)
                FROM examples WHERE rank<=5 ORDER BY confidence DESC,rank LIMIT 500
                """)
            rows += data.map { [.text(layer.title),$0[0],.text(graph.vocabulary.predicate($0[2].text ?? "")),$0[3],$0[4]] }
            targets += data.map { row in row[1].integer.map { GraphTarget(id:$0,layer:layer) } }
        }
        return [ReportSection("Confidence Examples", [
            Column("Layer"),Column("Confidence"),Column("Predicate"),Column("Example",privateValue:true),Column("Sources")
        ],rows,note:"Up to five examples per confidence value in each layer. Select a score to view its examples.",targets:targets,levelColumn:1)]
    }

    static func calendar(_ graph: GraphAccess, owner: Int64?) throws -> [ReportSection] {
        let ownerRef = owner.map { "md:\($0)" } ?? ""
        let authors = try graph.db.table("Event Description Source", [
            Column("Sender"),Column("Descriptions"),Column("Characters")
        ], """
            WITH attributed AS (
                SELECT d.object,
                    CASE WHEN EXISTS(SELECT 1 FROM event_graph s WHERE s.subject=d.subject AND s.predicate='PS580' AND s.object=?)
                         THEN 'Owner'
                         WHEN EXISTS(SELECT 1 FROM event_graph s WHERE s.subject=d.subject AND s.predicate='PS580' AND s.object GLOB 'md:*')
                         THEN 'Other Sender' ELSE 'Unspecified' END role
                FROM event_graph d WHERE d.predicate='PS51'
            )
            SELECT role,count(*),sum(length(object)) FROM attributed GROUP BY role ORDER BY count(*) DESC
            """,bindings:[.text(ownerRef)],note:"Estimated from the invitation sender role. The text may have another author.")
        let series = try graph.db.table("Recurring Meetings", [
            Column("Title",privateValue:true),Column("Events"),Column("Series Start"),Column("Series End")
        ], """
            WITH titled AS (
                SELECT DISTINCT subject,trim(object) name FROM event_graph
                WHERE predicate='PS33' AND length(trim(object))>0
            ), dated AS (
                SELECT subject,min(printf('%04d-%02d-%02d',json_extract(object,'$.year'),
                       json_extract(object,'$.month'),json_extract(object,'$.day'))) day
                FROM event_graph WHERE relationshipPredicate='PS29' AND json_valid(object)
                GROUP BY subject
            )
            SELECT name,count(DISTINCT titled.subject),min(day),max(day)
            FROM titled LEFT JOIN dated USING(subject) GROUP BY name COLLATE NOCASE
            HAVING count(DISTINCT titled.subject)>1 ORDER BY 2 DESC,1 LIMIT 200
            """,note:"A series groups different entities with the same title in the graph.")
        guard graph.layers.contains(.stable) else { return [authors,series] }
        let domains = try graph.db.table("Invitation Domains", [
            Column("Domain",privateValue:true),Column("People"),Column("Events"),
            Column("Participants"),Column("Organizers"),Column("Senders")
        ], """
            WITH roles AS (
              SELECT DISTINCT subject event,object person,predicate role FROM event_graph
              WHERE object GLOB 'md:*' AND object<>?
                AND ((predicate IN ('PS232','PS578') AND relationshipPredicate='PS143') OR predicate='PS580')
            ), mail AS (
              SELECT DISTINCT 'md:' || subject person,lower(substr(object,instr(object,'@')+1)) domain
              FROM stable_graph WHERE relationshipPredicate='PS406' AND instr(object,'@')>0
            )
            SELECT domain,count(DISTINCT person),count(DISTINCT event),
                count(DISTINCT CASE WHEN role='PS232' THEN person END),
                count(DISTINCT CASE WHEN role='PS578' THEN person END),
                count(DISTINCT CASE WHEN role='PS580' THEN person END)
            FROM roles JOIN mail USING(person) WHERE domain<>'' GROUP BY domain ORDER BY 3 DESC,2 DESC,1
            """,bindings:[.text(ownerRef)])
        return [authors,series,domains]
    }
}

extension ParityReports {
    static func contactEvidence(_ graph: GraphAccess, source: GraphSource) throws -> [ReportSection] {
        let names = try graph.knownNames()
        let records = try graph.db.cells("""
            SELECT DISTINCT h.subject,h.relationshipPredicate,h.object,h.sources,
                (SELECT min(m.object) FROM stable_graph m WHERE m.subject=h.subject
                    AND m.predicate=h.predicate AND m.relationshipId=h.relationshipId AND m.relationshipPredicate='PS740')
            FROM stable_graph h WHERE h.predicate='PS520' AND h.relationshipPredicate IN ('PS406','PS407')
            AND nullif(h.object,'') IS NOT NULL ORDER BY h.relationshipPredicate,h.subject,h.object
            """)
        func contactLabel(_ raw: Cell) -> String? {
            guard let text = raw.text else { return nil }
            if text.hasPrefix("_$!<"), text.hasSuffix(">!$_") { return String(text.dropFirst(4).dropLast(4)) }
            return text
        }
        var reverse: [[Cell]] = []
        var targets: [GraphTarget?] = []
        var labels: [String: Int64] = [:]
        var phone: Set<String> = [], email: Set<String> = []
        var peopleByAddress: [String: Set<Int64>] = [:]
        for row in records {
            guard let id = row[0].integer, let address = row[2].text else { continue }
            let isPhone = row[1].text == "PS407"
            if isPhone { phone.insert(address) } else { email.insert(address.lowercased()) }
            let label = contactLabel(row[4])
            if let label { labels[label, default: 0] += 1 }
            peopleByAddress[address.lowercased(), default: []].insert(id)
            let sources = row[3].integer.map(Evidence.sourceLabels(for:)) ?? []
            reverse.append([.text(address),.text(isPhone ? "Phone" : "Email"),label.map(Cell.text) ?? .empty,
                            GraphAccess.label(id,names),.text(sources.joined(separator: ", "))])
            targets.append(.init(id: id))
        }
        let rollup = try graph.db.cells("""
            WITH statements AS (
                SELECT subject,relationshipId,max(relationshipPredicate='PS407') phone,
                       max(relationshipPredicate='PS406') mail
                FROM stable_graph WHERE predicate='PS520' GROUP BY subject,relationshipId
            )
            SELECT subject,sum(phone),sum(mail),sum(phone=0 AND mail=0),count(*) FROM statements
            GROUP BY subject ORDER BY sum(phone+mail) DESC,subject
            """)
        var result = [
            ReportSection("People by Address or Phone Number", [
                Column("Address", privateValue: true),Column("Type"),Column("Label", privateValue: true),
                Column("Person", privateValue: true),Column("Sources")
            ],reverse,targets:targets),
            ReportSection("Phone and Address Labels", [Column("Label", privateValue: true),Column("Records")],
                labels.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .map { [.text($0.key),.integer($0.value)] }),
            ReportSection("Contact Records by Person", [
                Column("Person", privateValue: true),Column("Phone Numbers"),Column("Addresses"),
                Column("Other"),Column("Statements")
            ],rollup.map { row in
                [row[0].integer.map { GraphAccess.label($0,names) } ?? .empty] + row.dropFirst()
            }, targets:rollup.map { $0[0].integer.map { GraphTarget(id: $0) } }),
            ReportSection("Addresses Shared by Multiple Entities", [Column("Address", privateValue: true),Column("Entities")],
                peopleByAddress.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
                    .map { [.text($0.key),.integer(Int64($0.value.count))] })
        ]
        if let messages = try? LocalStore.messages.open(source),
           let values = try? messages.cells("SELECT DISTINCT lower(id) FROM handle WHERE nullif(id,'') IS NOT NULL") {
            let known = Set(values.compactMap { $0[0].text })
            func phoneTail(_ value: String) -> String? {
                let digits = value.filter(\.isNumber)
                return digits.count >= 9 ? String(digits.suffix(9)) : nil
            }
            let byTail = Set(phone.compactMap(phoneTail)).intersection(known.compactMap(phoneTail)).count
            result.append(ReportSection("Address Verification Against Messages", [
                Column("Addresses in Messages"),Column("Graph Phone Numbers"),Column("Graph Addresses"),Column("Exact Phone Matches"),
                Column("Exact Address Matches"),Column("Matched on Last 9 Digits")
            ], [[.integer(Int64(known.count)),.integer(Int64(phone.count)),.integer(Int64(email.count)),
                 .integer(Int64(phone.filter { known.contains($0.lowercased()) }.count)),.integer(Int64(email.intersection(known).count)),
                 .integer(Int64(byTail))]], note: "Matching the final digits checks for differences in phone number formatting."))
        }
        return result
    }
}
