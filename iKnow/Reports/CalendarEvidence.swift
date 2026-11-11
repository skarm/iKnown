import Foundation

struct UpcomingEvent: Identifiable, Sendable {
    let subject: Int64
    let title: String
    let starts: Date
    let clock: String
    let timeZone: String?
    let duration: Int64?
    let guests: [String]
    let attendeeCount: Int
    let includesOwner: Bool
    let conferenceLinks: Int64

    var id: String { "\(subject)/\(clock)" }
}

extension GraphAccess {
    func captureDate() throws -> Date? {
        let timestamps = try layers.compactMap { layer in
            try db.cells("SELECT max(timestamp) FROM \(layer.rawValue)").first?.first?.number
        }
        return timestamps.max().map(Date.init(timeIntervalSinceReferenceDate:))
    }

    func upcomingEvents() throws -> [UpcomingEvent] {
        guard layers.contains(.event), let capture = try captureDate() else { return [] }
        let names = try knownNames()
        let titles = try self.names(layer:.event)
        let attendees = try members(layer:.event,predicate:"PS232",facet:"PS143")
        let owner = try owner()
        let rows = try db.cells("""
            SELECT s.subject,s.object,
                (SELECT min(e.object) FROM event_graph e WHERE e.subject=s.subject
                    AND e.relationshipId=s.relationshipId AND e.relationshipPredicate='PS30'),
                EXISTS(SELECT 1 FROM event_graph a WHERE a.subject=s.subject
                    AND a.predicate='nm_isAllDay' AND a.object IN ('1','true')),
                (SELECT count(*) FROM event_graph l WHERE l.subject=s.subject
                    AND l.predicate='nm_virtualConferenceURL')
            FROM event_graph s WHERE s.relationshipPredicate='PS29' ORDER BY s.subject,s.object
            """)
        var byDate: [String:UpcomingEvent] = [:]
        for row in rows {
            guard let id = row[0].integer, let start = CalendarComponents(row[1].text),
                  start.date > capture else { continue }
            let allDay = row[3].integer == 1 || start.hour == nil
            let members = attendees[id,default:[]]
            let finish = CalendarComponents(row[2].text)
            let duration = finish.map { Int64($0.date.timeIntervalSince(start.date) / 60) }
            let item = UpcomingEvent(subject:id,title:titles[id] ?? "Untitled",starts:start.date,
                clock:allDay ? start.day : start.day + String(format:" %02d:%02d",start.hour ?? 0,start.minute),
                timeZone:start.timeZone,duration:duration,guests:members.sorted().filter { $0 != owner }.map { names[$0] ?? "ID \($0)" },
                attendeeCount:members.count,includesOwner:owner.map(members.contains) ?? false,conferenceLinks:row[4].integer ?? 0)
            byDate[item.id] = item
        }
        return byDate.values.sorted { ($0.starts,$0.subject) < ($1.starts,$1.subject) }
    }
}

private struct CalendarComponents: Decodable {
    let year: Int
    let month: Int
    let dayNumber: Int
    let hour: Int?
    let minutes: Int?
    let zone: Zone?

    struct Zone: Decodable { let identifier: String? }
    enum CodingKeys: String, CodingKey {
        case year, month, dayNumber = "day", hour, minutes = "minute", zone = "timeZone"
    }

    init?(_ text: String?) {
        guard let text, let result = try? JSONDecoder().decode(Self.self,from:Data(text.utf8)),
              (1...9999).contains(result.year), (1...12).contains(result.month),
              (1...31).contains(result.dayNumber), (0...23).contains(result.hour ?? 0),
              (0...59).contains(result.minute), result.validDate != nil else { return nil }
        self = result
    }

    private var validDate: Date? {
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = .gmt
        let parts = DateComponents(year:year,month:month,day:dayNumber,hour:hour ?? 0,minute:minute)
        guard let date = calendar.date(from:parts), calendar.component(.day,from:date) == dayNumber else { return nil }
        return date
    }

    // Original comparison interprets the stored wall clock as UTC.
    var date: Date { validDate ?? .distantPast }
    var day: String { String(format:"%04d-%02d-%02d",year,month,dayNumber) }
    var minute: Int { minutes ?? 0 }
    var timeZone: String? { zone?.identifier }
}

extension GraphAccess {
    func travelEvidence() throws -> [ReportSection] {
        let names = try knownNames()
        var codes: [Int64: String] = [:]
        if layers.contains(.stable) {
            for row in try db.cells("""
                SELECT subject, min(object) FROM stable_graph WHERE predicate='nm_iataCode' GROUP BY subject
                """) {
                if let id = row[0].integer { codes[id] = row[1].text }
            }
        }
        let reservations = try db.table("Siri Reservation Types", [Column("Type"), Column("Events")], """
            SELECT object, count(DISTINCT subject) FROM event_graph
            WHERE predicate='nm_sgEventType' GROUP BY object ORDER BY 2 DESC,1
            """)
        let legs = try db.cells("""
            WITH travel AS (
                SELECT DISTINCT subject FROM event_graph WHERE predicate='PS1' AND relationshipId=0 AND object='SB514'
            )
            SELECT g.subject,
                max(CASE WHEN predicate='PS33' AND relationshipId=0 THEN object END),
                max(CASE WHEN predicate='nm_iataCode' AND relationshipId=0 THEN object END),
                max(CASE WHEN predicate='nm_flightNumber' AND relationshipId=0 THEN object END),
                max(CASE WHEN predicate='PS248' AND relationshipId=0 THEN object END),
                max(CASE WHEN predicate='PS249' AND relationshipId=0 THEN object END),
                min(CASE WHEN relationshipPredicate='PS29' THEN object END),
                max(CASE WHEN predicate='PS51' AND relationshipId=0 THEN nullif(length(object),0) END)
            FROM event_graph g JOIN travel t ON t.subject=g.subject GROUP BY g.subject
            """)
        func airport(_ raw: Cell) -> Cell {
            guard let id = GraphAccess.reference(raw.text) else { return raw }
            let parts = [names[id], codes[id]].compactMap { $0 }
            return .text(parts.isEmpty ? "ID \(id)" : parts.joined(separator: " · "))
        }
        let ordered = legs.map { ($0, CalendarComponents($0[6].text)) }.sorted {
            ($0.1?.date ?? .distantPast, $0.0[0].integer ?? 0) < ($1.1?.date ?? .distantPast, $1.0[0].integer ?? 0)
        }
        let routes = ReportSection("Flights from Reservations", [
            Column("Starts", privateValue: true), Column("Event", privateValue: true),
            Column("Carrier", privateValue: true), Column("Flight", privateValue: true),
            Column("From", privateValue: true), Column("To", privateValue: true), Column("Description Length")
        ], ordered.map { row, time in
            let start = time.map { $0.day + String(format: " %02d:%02d", $0.hour ?? 0, $0.minute) }
            return [start.map(Cell.text) ?? .empty, row[1], row[2], row[3], airport(row[4]), airport(row[5]), row[7]]
        }, targets: ordered.map { $0.0[0].integer.map { GraphTarget(id: $0, layer: .event) } })
        let lengths = try db.table("Reservation and Meeting Descriptions", [
            Column("Type"), Column("Records"), Column("With a Description"), Column("Median Length")
        ], """
            WITH by_event AS (
                SELECT subject, max(predicate='nm_sgEventType') reservation,
                       max(CASE WHEN predicate='PS51' THEN nullif(length(object),0) END) chars
                FROM event_graph GROUP BY subject
            ), ranked AS (
                SELECT reservation,chars,row_number() OVER (PARTITION BY reservation ORDER BY chars) position,
                       count(*) OVER (PARTITION BY reservation) n
                FROM by_event WHERE chars IS NOT NULL
            )
            SELECT CASE WHEN b.reservation THEN 'Reservations' ELSE 'Other Events' END,
                   count(*),count(b.chars),
                   (SELECT r.chars FROM ranked r WHERE r.reservation=b.reservation AND r.position=r.n/2+1)
            FROM by_event b GROUP BY b.reservation ORDER BY b.reservation DESC
            """)
        return [reservations, routes, lengths]
    }

    func calendarSourceEvidence(_ original: SQLiteDatabase) throws -> [ReportSection] {
        let capture = try captureDate()?.timeIntervalSinceReferenceDate
        let fields = try original.columns(in: "CalendarItem")
        func available(_ key: String, _ expression: String) -> String { fields[key] == nil ? "NULL" : expression }
        var result = [try original.table("Calendar Source Coverage", [
            Column("Events"), Column("After Snapshot"), Column("With a Description"), Column("Characters"),
            Column("Detected Conference Links"), Column("With a Conference Field")
        ], """
            SELECT count(*), sum(start_date > ?),
                   \(available("description", "sum(nullif(description,'') IS NOT NULL)")),
                   \(available("description", "sum(length(description))")),
                   \(available("conference_url_detected", "sum(nullif(conference_url_detected,'') IS NOT NULL)")),
                   \(available("conference_url", "sum(nullif(conference_url,'') IS NOT NULL)"))
            FROM CalendarItem WHERE start_date IS NOT NULL
            """, bindings: [capture.map(SQLiteDatabase.Parameter.real) ?? .null])]
        if try !original.columns(in: "OccurrenceCache").isEmpty {
            result.append(try original.table("Occurrences in the Calendar Store", [
                Column("Occurrences"), Column("After Snapshot"), Column("Latest")
            ], """
                SELECT count(*), sum(occurrence_date > ?), date(max(occurrence_date)+978307200,'unixepoch')
                FROM OccurrenceCache WHERE occurrence_date IS NOT NULL
                """, bindings: [capture.map(SQLiteDatabase.Parameter.real) ?? .null]))
        }
        if try original.columns(in: "Participant")["owner_id"] != nil {
            result.append(try original.table("Meeting Sizes in the Calendar Store",
                [Column("Participants"), Column("Events")], """
                SELECT guests,count(*) FROM (
                    SELECT count(p.rowid) guests FROM CalendarItem c
                    LEFT JOIN Participant p ON p.owner_id=c.rowid GROUP BY c.rowid
                ) GROUP BY guests ORDER BY guests
                """))
        }
        if try original.columns(in: "Identity")["address"] != nil {
            result.append(try original.table("Addresses in the Calendar Store",
                [Column("Identities"), Column("Domains")], """
                SELECT count(*),count(DISTINCT CASE WHEN address LIKE '%@%' THEN
                    lower(substr(address,instr(address,'@')+1)) END) FROM Identity
                """))
        }
        let placeFields = try original.columns(in: "Location")
        if ["title", "address", "latitude", "longitude"].allSatisfy({ placeFields[$0] != nil }) {
            result.append(try original.table("Locations in the Calendar Store",
                [Column("Records"), Column("Distinct Names"), Column("With an Address"), Column("With Coordinates")], """
                SELECT count(*), count(DISTINCT title), sum(nullif(address,'') IS NOT NULL),
                       sum(latitude IS NOT NULL AND longitude IS NOT NULL AND (latitude<>0 OR longitude<>0))
                FROM Location WHERE nullif(title,'') IS NOT NULL
                """))
        }
        return result
    }
}

extension GraphAccess {
    func calendarRhythm() throws -> [ReportSection] {
        let dates = try db.cells("""
            SELECT s.subject,s.object,
                (SELECT min(e.object) FROM event_graph e WHERE e.subject=s.subject
                    AND e.relationshipId=s.relationshipId AND e.relationshipPredicate='PS30'),
                EXISTS(SELECT 1 FROM event_graph a WHERE a.subject=s.subject
                    AND a.predicate='nm_isAllDay' AND a.object IN ('1','true'))
            FROM event_graph s WHERE s.relationshipPredicate='PS29'
            """)
        var hours = Array(repeating: 0, count: 24)
        var weekdays = Array(repeating: 0, count: 7)
        var durations: [Int64: Int] = [:]
        var zones: [String: Int] = [:]
        let capture = try captureDate()
        var closest: TimeInterval?
        var before = 0
        var after = 0
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .gmt
        for row in dates {
            guard let start = CalendarComponents(row[1].text) else { continue }
            let weekday = (calendar.component(.weekday, from: start.date) + 5) % 7
            weekdays[weekday] += 1
            if let hour = start.hour, row[3].integer != 1 {
                hours[hour] += 1
                if let finish = CalendarComponents(row[2].text) {
                    let duration = Int64(floor(finish.date.timeIntervalSince(start.date) / 60))
                    durations[duration, default: 0] += 1
                }
            }
            if let zone = start.timeZone { zones[zone, default: 0] += 1 }
            if let capture {
                let gap = start.date.timeIntervalSince(capture)
                if gap > 0 { after += 1 } else { before += 1 }
                closest = min(closest ?? abs(gap), abs(gap))
            }
        }
        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let durationRows = durations.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var result = [
            ReportSection("Event Start Times by Hour", [Column("Hour"), Column("Dates")],
                hours.enumerated().map { [.text(String(format: "%02d:00", $0.offset)), .integer(Int64($0.element))] }, style: .bars),
            ReportSection("Events by Day of Week", [Column("Day"), Column("Dates")],
                zip(dayLabels, weekdays).map { [.text($0), .integer(Int64($1))] }, style: .bars),
            ReportSection("Event Duration", [Column("Minutes"), Column("Dates")],
                durationRows.map { [.integer($0.key), .integer(Int64($0.value))] }, style: .bars),
            ReportSection("Event Time Zones", [Column("Time Zone", privateValue: true), Column("Dates")],
                zones.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .map { [.text($0.key), .integer(Int64($0.value))] }),
            try db.table("Text Volume in Calendar", [
                Column("Field"), Column("Rows"), Column("Events"), Column("Characters"), Column("Maximum Length")
            ], """
                SELECT coalesce(nullif(relationshipPredicate,''),predicate),count(*),count(DISTINCT subject),
                       sum(length(object)),max(length(object)) FROM event_graph
                WHERE predicate IN ('PS33','PS51','PS225','nm_virtualConferenceURL')
                AND nullif(object,'') IS NOT NULL GROUP BY 1 ORDER BY 4 DESC
                """)
        ]
        if let capture {
            result.append(ReportSection("Snapshot Cutoff", [
                Column("Last Record", privateValue: true), Column("Dates Before Snapshot"),
                Column("Dates After Snapshot"), Column("Hours to Nearest Event")
            ], [[.text(capture.ISO8601Format()), .integer(Int64(before)), .integer(Int64(after)),
                 closest.map { .real($0 / 3600) } ?? .empty]],
                 note: "For comparison, event times in the graph are interpreted as UTC."))
        }
        return result
    }
}
