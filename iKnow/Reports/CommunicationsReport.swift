import Foundation

enum CommunicationsReport {
    static func load(_ source: GraphSource) throws -> Report {
        let db = try LocalStore.interactions.open(source)
        let columns = try db.columns(in: "interactions")
        guard ["startDate", "bundleId", "domain", "direction"].allSatisfy({ columns[$0] != nil })
        else { throw GraphFailure.schema }
        let filter = "domain IN ('Calls','Messages')"
        let total = try db.count("SELECT count(*) FROM interactions WHERE \(filter)")
        let calls = try db.count("SELECT count(*) FROM interactions WHERE domain='Calls'")
        let apps = try db.count("SELECT count(DISTINCT bundleId) FROM interactions WHERE \(filter)")
        let span = try db.cells("""
            SELECT date(min(startDate)+978307200,'unixepoch','localtime'),
                   date(max(startDate)+978307200,'unixepoch','localtime')
            FROM interactions WHERE \(filter)
            """).first
        let (directions,inbound,outbound) = try directionExpressions(db)
        let date = "startDate+978307200,'unixepoch','localtime'"
        let privateName = Column("Name", privateValue: true)
        let bundle = Column("App", privateValue: true)
        let directionColumns = [Column("Total"), Column("Incoming"), Column("Outgoing")]
        var report = Report(metrics: [
            Metric("Interactions", total), Metric("Calls", calls), Metric("Apps", apps),
            Metric("Log Date Range", text: span.map { $0[0].label + " — " + $0[1].label } ?? "—")
        ])
        let rhythm = try db.table("Weekly Activity", [Column("Day"), Column("Hour"), Column("Records")], """
            SELECT (CAST(strftime('%w',\(date)) AS INTEGER)+6)%7,
              CAST(strftime('%H',\(date)) AS INTEGER), count(*) FROM interactions
            WHERE \(filter) AND startDate IS NOT NULL GROUP BY 1,2 ORDER BY 1,2
            """, style: .weekly, note: "Times are local to this Mac. Each cell totals one hour of the week across the log.")
        report.sections.append(rhythm)
        let quiet = quietHours(rhythm.rows)
        if let quiet {
            report.sections.append(ReportSection("Quiet Hours", [Column("Interval"), Column("Records"), Column("Share")], [
                [.text(String(format: "%02d:00 – %02d:00", quiet.start, quiet.end)), .integer(quiet.count),
                 .text(quiet.share.formatted(.percent.locale(.iKnow).precision(.fractionLength(1))))]
            ], note: "The interval is estimated from event frequency in the log metadata."))
        }
        report.sections.append(try db.table("Monthly Communication", [Column("Month")] + directionColumns, """
            SELECT strftime('%Y-%m',\(date)),count(*),\(inbound),\(outbound)
            FROM interactions WHERE \(filter) AND startDate IS NOT NULL GROUP BY 1 ORDER BY 1
            """, style: .series))
        report.sections.append(try db.table("By App", [bundle] + directionColumns + [Column("Calls")], """
            SELECT bundleId,count(*),\(inbound),\(outbound),sum(domain='Calls')
            FROM interactions WHERE \(filter) GROUP BY bundleId ORDER BY count(*) DESC, bundleId
            """))
        let (personCTE,personFilter,nameBinding) = personQuery(source)
        report.sections.append(try correspondents(db,source:source,inbound:inbound,outbound:outbound,limit:200))
        report.sections.append(try db.table("Contacts by App", [privateName, bundle] + directionColumns, """
            \(personCTE)
            SELECT p.name,i.bundleId,count(*),\(inbound),\(outbound)
            FROM people p JOIN interactions i ON i.rowid=p.interaction \(personFilter)
            GROUP BY p.name,i.bundleId ORDER BY count(*) DESC,p.name,i.bundleId LIMIT 200
            """, bindings: nameBinding))
        report.sections.append(try db.table("Monthly Calls",
            [Column("Month"),Column("Calls"),Column("With a Duration"),Column("Seconds")], """
            SELECT strftime('%Y-%m',\(date)),count(*),sum(durationSeconds>0),sum(max(durationSeconds,0))
            FROM interactions WHERE domain='Calls' AND startDate IS NOT NULL GROUP BY 1 ORDER BY 1
            """, style: .series))
        report.sections.append(try db.table("Call Statuses",
            [Column("Code"),Column("Calls"),Column("With a Duration"),Column("Seconds")], """
            SELECT handlingStatus,count(*),sum(durationSeconds>0),sum(max(durationSeconds,0))
            FROM interactions WHERE domain='Calls' GROUP BY handlingStatus ORDER BY count(*) DESC
            """, note: "A recorded duration distinguishes conversations from other call events."))
        report.sections.append(try db.table("Monthly Talk Time", [Column("Month"),Column("Minutes")], """
            SELECT strftime('%Y-%m',\(date)),sum(max(durationSeconds,0))/60.0
            FROM interactions WHERE domain='Calls' AND startDate IS NOT NULL GROUP BY 1 ORDER BY 1
            """, style: .series))
        report.sections.append(try db.table("Share of Calls with a Duration",
            [Column("App",privateValue:true),Column("Records"),Column("With a Duration"),Column("Share")], """
            SELECT bundleId,count(*),sum(coalesce(durationSeconds,0)>0),avg(coalesce(durationSeconds,0)>0)
            FROM interactions WHERE domain='Calls' GROUP BY bundleId ORDER BY 2 DESC,1
            """))
        report.sections.append(try db.table("Contacts by Talk Time", [
            privateName,Column("Calls"),Column("Incoming"),Column("Outgoing"),Column("Minutes")
        ], """
            \(personCTE)
            SELECT p.name,count(*),\(inbound),\(outbound),sum(max(i.durationSeconds,0))/60.0 AS minutes
            FROM people p JOIN interactions i ON i.rowid=p.interaction
            \(personFilter) \(personFilter.isEmpty ? "WHERE" : "AND") i.domain='Calls'
            GROUP BY p.name ORDER BY minutes DESC,p.name
            """, bindings: nameBinding))
        report.sections.append(try db.table("Group Interactions",
            [Column("App", privateValue: true), Column("Participants"), Column("Records")], """
            \(personCTE), groups AS (SELECT interaction,count(*) n FROM people GROUP BY interaction HAVING n>1)
            SELECT i.bundleId,groups.n,count(*) FROM groups JOIN interactions i ON i.rowid=groups.interaction
            GROUP BY i.bundleId,groups.n ORDER BY count(*) DESC LIMIT 150
            """))
        report.sections.append(try db.table("Conversations by Log Key",
            [Column("Key", privateValue: true), bundle, Column("Domain"), Column("Records"), Column("Last Seen")], """
            SELECT contentHash,bundleId,domain,count(*),date(max(startDate)+978307200,'unixepoch','localtime')
            FROM interactions WHERE \(filter) AND contentHash IS NOT NULL
            GROUP BY contentHash,bundleId,domain ORDER BY count(*) DESC LIMIT 100
            """, note: "One key can group several events from the same conversation."))
        report.sections.append(try db.table("Devices and Siri",
            [Column("Device", privateValue: true), Column("Siri"), Column("Domain"), Column("Records")], """
            SELECT coalesce(nullif(remoteDeviceId,''),'Local Record'),isDonatedBySiri,domain,count(*)
            FROM interactions WHERE \(filter) GROUP BY 1,2,3 ORDER BY count(*) DESC LIMIT 120
            """))
        report.sections.append(try db.table("What the Log Contains",
            [Column("Object Type"), Column("Objects"), Column("Object Fields")], """
            SELECT type,count(*),sum(CASE WHEN json_valid(fields) AND fields NOT IN ('','{}','[]') THEN 1 ELSE 0 END)
            FROM entities GROUP BY type ORDER BY count(*) DESC
            """, note: "Totals are grouped by object. Message content is not extracted."))
        report.sections.append(try db.table("Log Roles", [Column("Role"),Column("Interactions"),Column("Objects")], """
            SELECT l.parameter,count(DISTINCT l.interactionRowid),count(DISTINCT l.entityRowid)
            FROM interactionEntities l JOIN interactions i ON i.rowid=l.interactionRowid
            WHERE i.domain IN ('Messages','Calls') GROUP BY l.parameter ORDER BY count(*) DESC
            """))
        report.sections.append(try db.table("Communication Reciprocity", [privateName] + directionColumns + [Column("Reciprocity")], """
            \(personCTE), volumes AS (
                SELECT p.name AS name,count(*) AS total,\(inbound) AS incoming,\(outbound) AS outgoing
                FROM people p JOIN interactions i ON i.rowid=p.interaction \(personFilter) GROUP BY p.name
            )
            SELECT name,total,incoming,outgoing,
                   CASE WHEN incoming+outgoing>0 THEN 2.0*min(incoming,outgoing)/(incoming+outgoing) END
            FROM volumes ORDER BY total DESC,name LIMIT 150
            """, bindings: nameBinding,
            note: "A value of 1 means equal incoming and outgoing activity. A value of 0 means one-way activity."))
        report.sections.append(try db.table("Least Recently Contacted", [privateName,Column("Records"),Column("Last Record"),Column("Days Before End of Log")], """
            \(personCTE), last AS (SELECT max(startDate) AS latest FROM interactions WHERE \(filter))
            SELECT p.name,count(*),date(max(i.startDate)+978307200,'unixepoch','localtime'),
                   CAST((max(last.latest)-max(i.startDate))/86400 AS INTEGER) AS age
            FROM people p JOIN interactions i ON i.rowid=p.interaction CROSS JOIN last \(personFilter)
            GROUP BY p.name HAVING age>=30 ORDER BY age DESC,p.name LIMIT 100
            """, bindings:nameBinding))
        if let quiet {
            let hour = "CAST(strftime('%H',\(date)) AS INTEGER)"
            let hours = quiet.start < quiet.end
                ? "\(hour) >= \(quiet.start) AND \(hour) < \(quiet.end)"
                : "(\(hour) >= \(quiet.start) OR \(hour) < \(quiet.end))"
            let whereClause = personFilter.isEmpty ? "WHERE \(hours)" : "\(personFilter) AND \(hours)"
            report.sections.append(try db.table("Communication During Quiet Hours", [privateName] + directionColumns, """
                \(personCTE)
                SELECT p.name,count(*),\(inbound),\(outbound)
                FROM people p JOIN interactions i ON i.rowid=p.interaction
                \(whereClause) GROUP BY p.name ORDER BY count(*) DESC,p.name LIMIT 100
                """, bindings:nameBinding))
        }
        report.sections.append(try db.table("Interaction Fields", [
            Column("Domain"),Column("Field"),Column("Records"),Column("Maximum Bytes")
        ], """
            SELECT i.domain,j.key,count(*),max(length(CAST(j.value AS BLOB)))
            FROM interactions i, json_each(CASE WHEN json_valid(i.fields) THEN i.fields ELSE '{}' END) j
            WHERE i.domain IN ('Messages','Calls') GROUP BY 1,2 ORDER BY count(*) DESC LIMIT 200
            """, note:"The table shows field names and sizes."))
        report.sections.append(try db.table("Conversation Key Reuse",[
            Column("Keys"),Column("Single Use"),Column("Repeated"),Column("With Different Participants")
        ], """
            WITH combinations AS (
                SELECT i.contentHash AS key,i.bundleId,i.domain,i.direction,
                    coalesce((SELECT group_concat(link.entityRowid, ',' ORDER BY link.entityRowid)
                              FROM interactionEntities link WHERE link.interactionRowid=i.rowid),'') AS participants
                FROM interactions i WHERE \(filter) AND contentHash IS NOT NULL
            ), repeated AS (
                SELECT key,count(*) AS n,count(DISTINCT json_array(bundleId,domain,direction,participants)) AS variants
                FROM combinations GROUP BY key
            )
            SELECT count(*),sum(n=1),sum(n>1),sum(variants>1) FROM repeated
            """, note:"A key can appear with different apps, roles, and participants."))
        report.sections.append(try db.table("First Records by App",[
            bundle,Column("First Month"),Column("Records")
        ], """
            SELECT bundleId,strftime('%Y-%m',min(startDate)+978307200,'unixepoch','localtime'),count(*)
            FROM interactions WHERE \(filter) AND startDate IS NOT NULL
            GROUP BY bundleId ORDER BY min(startDate),bundleId LIMIT 150
            """, note:"First appearance in the retained log."))
        report.sections.append(try db.table("Largest Monthly Increase in Activity", [
            Column("Month"),Column("Previous"),Column("Records"),Column("Earlier"),Column("Increase"),
            Column("New Apps"),Column("Records from New Apps"),Column("Share from New Apps (%)")
        ], """
            WITH activity AS (
                SELECT strftime('%Y-%m',\(date)) month,bundleId
                FROM interactions WHERE \(filter) AND startDate IS NOT NULL
            ), monthly AS (
                SELECT month,count(*) n FROM activity WHERE month IS NOT NULL GROUP BY month
            ), changes AS (
                SELECT month,n,lag(month) OVER(ORDER BY month) prior_month,lag(n) OVER(ORDER BY month) prior FROM monthly
            ), peak AS (
                SELECT *,n-prior AS delta FROM changes WHERE prior IS NOT NULL ORDER BY delta DESC,month DESC LIMIT 1
            ), first_seen AS (
                SELECT bundleId,min(month) first_month FROM activity WHERE bundleId IS NOT NULL GROUP BY bundleId
            ), contributions AS (
                SELECT count(DISTINCT a.bundleId) apps,count(*) hits FROM activity a
                JOIN first_seen f ON f.bundleId=a.bundleId AND f.first_month=a.month JOIN peak p ON p.month=a.month
            )
            SELECT month,prior_month,n,prior,delta,apps,hits,100.0*hits/n FROM peak CROSS JOIN contributions
            """, note:"An app first appears when it has its first record in the available log."))
        report.sections.append(directions)
        return report
    }

    private static let domainFilter = "domain IN ('Calls','Messages')"

    static func directionExpressions(_ db: SQLiteDatabase) throws -> (ReportSection,String,String) {
        let directions = try db.table("How Direction Was Inferred", [
            Column("Direction Code"), Column("Records"), Column("With a Sender"), Column("With a Recipient")
        ], """
            SELECT i.direction,count(*),
              sum(EXISTS(SELECT 1 FROM interactionEntities e
                         WHERE e.interactionRowid=i.rowid AND parameter='sender')),
              sum(EXISTS(SELECT 1 FROM interactionEntities e
                         WHERE e.interactionRowid=i.rowid AND
                         parameter IN ('recipients','contacts','recipientHandles','contactHandles')))
            FROM interactions i WHERE \(domainFilter) GROUP BY i.direction
            ORDER BY i.direction
            """, note: "Direction codes are inferred from this database.")
        let incoming = directions.rows
            .filter { ($0[2].integer ?? 0) > 0 && $0[0].integer != nil }
            .max { ($0[2].integer ?? 0) < ($1[2].integer ?? 0) }?[0].integer
        let outgoing = directions.rows
            .filter { ($0[3].integer ?? 0) > 0 && $0[0].integer != nil && $0[0].integer != incoming }
            .max { ($0[3].integer ?? 0) < ($1[3].integer ?? 0) }?[0].integer
        let inbound = incoming.map { "sum(direction = \($0))" } ?? "NULL"
        let outbound = outgoing.map { "sum(direction = \($0))" } ?? "NULL"
        return (directions,inbound,outbound)
    }

    private static func personQuery(_ source: GraphSource) -> (String,String,[SQLiteDatabase.Parameter]) {
        let personCTE = """
            WITH participants AS (
              SELECT DISTINCT i.rowid AS interaction, e.rowid AS person,
                coalesce(CASE WHEN json_valid(e.fields) THEN nullif(json_extract(e.fields,'$.name'),'') END,
                         'ID ' || e.rowid) AS name
              FROM interactions i JOIN interactionEntities l ON l.interactionRowid=i.rowid
              JOIN entities e ON e.rowid=l.entityRowid
              WHERE i.domain IN ('Messages','Calls') AND e.type='Person'
            ), people AS (
              SELECT DISTINCT interaction,name FROM participants
            )
            """
        let ownerName: String?
        if let graph = try? GraphAccess(source), let id = try? graph.owner() {
            ownerName = try? graph.knownNames()[id]
        } else {
            ownerName = nil
        }
        let personFilter = ownerName == nil ? "" : "WHERE p.name <> ?"
        let nameBinding = ownerName.map { [SQLiteDatabase.Parameter.text($0)] } ?? []
        return (personCTE,personFilter,nameBinding)
    }

    private static func correspondents(_ db: SQLiteDatabase, source: GraphSource, inbound: String,
                                       outbound: String, limit: Int64) throws -> ReportSection {
        let (personCTE,personFilter,nameBinding) = personQuery(source)
        let privateName = Column("Name",privateValue:true)
        let directionColumns = [Column("Total"),Column("Incoming"),Column("Outgoing")]
        return try db.table("Contacts", [privateName] + directionColumns +
            [Column("Calls"), Column("Channels"), Column("First Seen"), Column("Last Seen")], """
            \(personCTE)
            SELECT p.name,count(*),\(inbound),\(outbound),sum(i.domain='Calls'),
                   count(DISTINCT i.bundleId),date(min(startDate)+978307200,'unixepoch','localtime'),
                   date(max(startDate)+978307200,'unixepoch','localtime')
            FROM people p JOIN interactions i ON i.rowid=p.interaction \(personFilter)
            GROUP BY p.name ORDER BY count(*) DESC, p.name LIMIT ?
            """, bindings: nameBinding + [.integer(limit)], note: "Up to 200 names, ordered by communication frequency. Matching labels in the log are grouped together.")
    }

    static func home(_ source: GraphSource) throws -> HomeCard {
        let db = try LocalStore.interactions.open(source)
        let total = try db.count("SELECT count(*) FROM interactions WHERE " + domainFilter)
        let (_,inbound,outbound) = try directionExpressions(db)
        let people = try correspondents(db,source:source,inbound:inbound,outbound:outbound,limit:8)
        let rows = people.rows.enumerated().map { index,row in
            HomeEntry(id:String(index),title:row[0].label,
                      subtitle:"Incoming "+row[2].label+" · outgoing "+row[3].label+" · calls "+row[4].label,
                      value:row[1].label)
        }
        let hours = try db.cells("""
            SELECT 0,CAST(strftime('%H',startDate+978307200,'unixepoch','localtime') AS INTEGER),count(*)
            FROM interactions WHERE \(domainFilter) AND startDate IS NOT NULL GROUP BY 2
            """)
        let detail = quietHours(hours).map { value in
            String(format:"Quiet hours %02d:00–%02d:00 · %lld records",value.start,value.end,value.count)
        } ?? "Messages and calls in the log"
        return HomeCard(page:.communications,value:.integer(total),detail:detail,rows:rows)
    }

    private static func quietHours(_ rows: [[Cell]]) -> (start: Int, end: Int, count: Int64, share: Double)? {
        var hours = Array(repeating: Int64(0), count: 24)
        for row in rows {
            guard let hour = row[1].integer, (0..<24).contains(hour) else { continue }
            hours[Int(hour)] += row[2].integer ?? 0
        }
        let total = hours.reduce(0, +)
        guard total > 0 else { return nil }
        let threshold = Double(total) / 96
        let quiet = hours.map { Double($0) < threshold }
        var best: (start: Int, length: Int, count: Int64)?
        for start in 0..<24 where quiet[start] && !quiet[(start+23)%24] {
            var length = 0
            var count: Int64 = 0
            while length < 24 && quiet[(start+length)%24] {
                count += hours[(start+length)%24]
                length += 1
            }
            if length > (best?.length ?? 0) { best = (start, length, count) }
        }
        return best.map { ($0.start, ($0.start+$0.length)%24, $0.count, Double($0.count)/Double(total)) }
    }
}
