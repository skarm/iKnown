import Foundation
import ImageIO

struct FaceAsset: Identifiable, Sendable {
    let id: Int64
    let uuid: String?
    let created: Date?
    let x: Double?
    let y: Double?
    let size: Double?
    let quality: Double?
    let orientation: Int64
    let hidden: Bool
    let trashed: Bool
    let path: URL?

    var point: CGPoint? {
        guard let x, let y, (0...1).contains(x), (0...1).contains(y) else { return nil }
        let top = 1 - y
        return switch orientation {
        case 2: CGPoint(x: 1-x, y: top)
        case 3: CGPoint(x: 1-x, y: y)
        case 4: CGPoint(x: x, y: y)
        case 5: CGPoint(x: top, y: x)
        case 6: CGPoint(x: y, y: x)
        case 7: CGPoint(x: y, y: 1-x)
        case 8: CGPoint(x: top, y: 1-x)
        default: CGPoint(x: x, y: top)
        }
    }
}

enum PhotosReport {
    private static let facePresence = """
        WITH present AS (
            SELECT DISTINCT f.ZPERSONFORFACE AS person, f.ZASSETFORFACE AS asset
            FROM ZDETECTEDFACE f JOIN ZPERSON p ON p.Z_PK = f.ZPERSONFORFACE
            WHERE f.ZASSETFORFACE > 0
        )
        """

    static func index(_ source: GraphSource) throws -> FaceIndex {
        let db = try LocalStore.photos.open(source)
        let fields = try db.columns(in:"ZPERSON")
        guard fields["Z_PK"] != nil else { throw GraphFailure.schema }
        let bindings = (try? graphBindings(source)) ?? [:]
        return try FaceIndex(clusters:clusters(db,fields:fields,bindings:bindings),pairs:cooccurrence(db))
    }

    static func load(_ source: GraphSource) throws -> Report {
        let db = try LocalStore.photos.open(source)
        let peopleFields = try db.columns(in: "ZPERSON")
        let faceFields = try db.columns(in: "ZDETECTEDFACE")
        guard peopleFields["Z_PK"] != nil, faceFields["ZPERSONFORFACE"] != nil,
              faceFields["ZASSETFORFACE"] != nil else { throw GraphFailure.schema }
        let bindings = (try? graphBindings(source)) ?? [:]
        let people = try clusters(db, fields: peopleFields, bindings: bindings)
        let total = try db.count("SELECT count(*) FROM ZDETECTEDFACE")
        let named = people.filter(\.isNamed).count
        let referenced = people.filter { !$0.graphTargets.isEmpty }.count
        let shared = try db.count("""
            \(facePresence)
            SELECT count(*) FROM (
                SELECT asset FROM present GROUP BY asset HAVING count(*) > 1
            )
            """)
        let pairs = try cooccurrence(db)
        var report = Report(metrics: [
            Metric("Clusters", Int64(people.count)), Metric("Faces", total),
            Metric("Named Clusters", Int64(named)), Metric("Shared Photos", shared)
        ], faces: FaceIndex(clusters: people, pairs: pairs))
        let clusterColumns = [Column("Cluster", privateValue: true), Column("Faces"), Column("Photos"),
            Column("Photos Cache"), Column("Graph Connections"), Column("Verification")]
        report.sections.append(ReportSection("Photos Clusters", clusterColumns, people.prefix(300).map { person in
            [.text(person.name), .integer(person.faces), .integer(person.photos), person.cachedCount.map(Cell.integer) ?? .empty,
             .integer(Int64(person.graphTargets.count)), person.verified.map(Cell.integer) ?? .empty]
        }, note: "Up to 300 clusters. Face counts come from detector records. The Photos cache may differ."))
        report.sections.append(ReportSection("Graph Connection Coverage", [Column("Metric"), Column("Clusters")], [
            [.text("Named in Photos"), .integer(Int64(named))],
            [.text("Linked to a Graph Entity"), .integer(Int64(referenced))],
            [.text("Have a Representative Face"), .integer(Int64(people.filter { $0.keyFace != nil }.count))],
            [.text("Have No Detector Records"), .integer(Int64(people.filter { $0.faces == 0 }.count))]
        ], style: .bars, note: "Links are verified using the phPerson UUID when the graph is available."))
        report.sections.append(try db.table("Photos with Faces by Month", [Column("Month"), Column("Photos"), Column("Faces")], """
            SELECT strftime('%Y-%m',a.ZDATECREATED+978307200,'unixepoch'),
                   count(DISTINCT a.Z_PK),count(*)
            FROM ZDETECTEDFACE f JOIN ZASSET a ON a.Z_PK=f.ZASSETFORFACE
            WHERE a.ZDATECREATED IS NOT NULL GROUP BY 1 ORDER BY 1
            """, style: .series))
        if try db.columns(in: "ZASSET")["ZKIND"] != nil {
            report.sections.append(try db.table("Photos and Videos by Month", [
                Column("Month"),Column("Photos"),Column("Videos"),Column("Other")
            ], """
                SELECT strftime('%Y-%m', ZDATECREATED+978307200, 'unixepoch'),
                       sum(ZKIND=0),sum(ZKIND=1),sum(ZKIND NOT IN (0,1))
                FROM ZASSET WHERE ZDATECREATED IS NOT NULL GROUP BY 1 ORDER BY 1
                """, style: .series))
        }
        report.sections.append(try db.table("People in Photos by Month", [Column("Month"),Column("Clusters")], """
            SELECT strftime('%Y-%m', a.ZDATECREATED+978307200, 'unixepoch'),count(DISTINCT f.ZPERSONFORFACE)
            FROM ZDETECTEDFACE f JOIN ZASSET a ON a.Z_PK=f.ZASSETFORFACE
            WHERE a.ZDATECREATED IS NOT NULL AND f.ZPERSONFORFACE>0 GROUP BY 1 ORDER BY 1
            """, style: .series))
        report.sections.append(try db.table("Faceprint Storage", [Column("Records"), Column("Bytes"), Column("Average Size")], """
            SELECT count(*),sum(length(ZDATA)),avg(length(ZDATA)) FROM ZFACEPRINT
            """, note: "The table shows record sizes. Faceprints stay in SQLite."))
        let attributes = [
            "ZAGETYPE","ZGENDERTYPE","ZETHNICITYTYPE","ZSKINTONETYPE","ZHAIRCOLORTYPE","ZHAIRTYPE",
            "ZFACIALHAIRTYPE","ZGLASSESTYPE","ZHEADGEARTYPE","ZEYESSTATE","ZGAZETYPE","ZFACEEXPRESSIONTYPE",
            "ZSMILETYPE","ZPOSETYPE","ZEYEMAKEUPTYPE","ZLIPMAKEUPTYPE"
        ].filter { faceFields[$0] != nil }
        let flags = ["ZHASSMILE","ZHASFACEMASK","ZSMILINGTYPE","ZEYECLOSED"].filter { faceFields[$0] != nil }
        var measured: [[Cell]] = []
        for (table, fields, kind) in [
            ("ZDETECTEDFACE",attributes,"Face Attribute"),
            ("ZDETECTEDFACE",flags,"Flag"),
            ("ZPERSON",["ZAGETYPE","ZGENDERTYPE"].filter { peopleFields[$0] != nil },"Cluster Attribute")
        ] {
            for field in fields {
                let column = SQLiteDatabase.identifier(field)
                let rows = try db.cells("SELECT count(*),sum(\(column)<>0),count(DISTINCT \(column)) FROM \(table)")
                if let row = rows.first { measured.append([.text(field),.text(kind)] + row) }
            }
        }
        if !measured.isEmpty {
            report.sections.append(ReportSection("Face Detector Measurements", [
                Column("Field"),Column("Type"),Column("Rows"),Column("Nonzero"),Column("Distinct Codes")
            ], measured, note: "For attributes, 0 usually means the value was not calculated. For flags, 0 means no."))
        }
        let cache = people.compactMap { cluster -> [Cell]? in
            guard let cached = cluster.cachedCount, cached != cluster.faces else { return nil }
            return [.text(cluster.name),.integer(cluster.faces),.integer(cached),.integer(cluster.faces-cached)]
        }.sorted { abs($0[3].number ?? 0) > abs($1[3].number ?? 0) }
        report.sections.append(ReportSection("Cache Discrepancies", [
            Column("Cluster",privateValue:true),Column("Detector Records"),Column("Cache"),Column("Difference")
        ],Array(cache.prefix(30))))
        report.sections.append(try db.table("Geography", [Column("Assets"), Column("With Coordinates")], """
            SELECT count(*),sum(ZLATITUDE BETWEEN -90 AND 90 AND ZLONGITUDE BETWEEN -180 AND 180
                   AND NOT (ZLATITUDE=0 AND ZLONGITUDE=0)) FROM ZASSET
            """, note: "The table shows aggregate coordinate counts."))
        report.sections.append(try db.table("Time Zones",
            [Column("Time Zone", privateValue: true), Column("Assets")], """
            SELECT ZTIMEZONENAME,count(*) FROM ZADDITIONALASSETATTRIBUTES
            WHERE ZTIMEZONENAME IS NOT NULL GROUP BY 1 ORDER BY count(*) DESC LIMIT 100
            """))
        report.sections += try memories(db)
        report.sections.append(try db.table("Scenes", [Column("Code"), Column("Type"), Column("Records"), Column("Average Confidence")], """
            SELECT ZSCENEIDENTIFIER,ZCLASSIFICATIONTYPE,count(*),avg(ZCONFIDENCE)
            FROM ZSCENECLASSIFICATION GROUP BY 1,2 ORDER BY count(*) DESC LIMIT 150
            """))
        report.hasSceneJoin = !(try db.columns(in:"ZMEDIAANALYSISASSETATTRIBUTES")).isEmpty
        report.sections += try ParityReports.photoDetails(db,source:source)
        return report
    }

    private static func memories(_ db: SQLiteDatabase) throws -> [ReportSection] {
        let fields = try db.columns(in: "ZMEMORY")
        guard !fields.isEmpty else { return [] }
        func field(_ key: String) -> String {
            fields[key] == nil ? "NULL" : SQLiteDatabase.identifier(key)
        }
        let titled = "nullif(\(field("ZTITLE")), '') IS NOT NULL"
        let views = field("ZVIEWCOUNT")
        let plays = field("ZPLAYCOUNT")
        let rejected = field("ZREJECTED")
        let shared = field("ZSHARECOUNT")
        let created = field("ZCREATIONDATE")
        let lastViewed = field("ZLASTVIEWEDDATE")
        var result = [
            try db.table("Memories Engagement", [
                Column("Total"), Column("With a Title"), Column("Views"), Column("Viewed"),
                Column("Plays"), Column("Played"), Column("Rejected"),
                Column("Shared"), Column("With a View Date")
            ], """
                SELECT count(*), sum(\(titled)), sum(\(views)), sum(\(views)>0), sum(\(plays)),
                       sum(\(plays)>0), sum(\(rejected)<>0), sum(\(shared)>0), sum(\(lastViewed) IS NOT NULL)
                FROM ZMEMORY
                """),
            try db.table("Memories", [
                Column("Category"), Column("Subcategory"), Column("Records"), Column("With a Title"),
                Column("Views"), Column("Plays"), Column("Rejected"),
                Column("First Seen", privateValue: true), Column("Last Seen", privateValue: true)
            ], """
                SELECT \(field("ZCATEGORY")), \(field("ZSUBCATEGORY")), count(*), sum(\(titled)), sum(\(views)),
                       sum(\(plays)), sum(\(rejected)<>0), date(min(\(created))+978307200,'unixepoch'),
                       date(max(\(created))+978307200,'unixepoch')
                FROM ZMEMORY GROUP BY 1,2 ORDER BY 3 DESC,1,2
                """)
        ]
        let memoryFields = try db.columns(in:"Z_3MEMORIESBEINGCURATEDASSETS")
        if memoryFields.count == 2,
           let asset = memoryFields.keys.sorted().first(where:{ $0.contains("CURATEDASSETS") && !$0.contains("MEMORIES") }),
           let memory = memoryFields.keys.sorted().first(where:{ $0.contains("MEMORIES") }) {
            result.append(try db.table("Assets in Memories", [
                Column("Connections"),Column("Memories"),Column("Assets")
            ], """
                SELECT count(*),count(DISTINCT \(SQLiteDatabase.identifier(memory))),
                       count(DISTINCT \(SQLiteDatabase.identifier(asset))) FROM Z_3MEMORIESBEINGCURATEDASSETS
                """))
        }
        return result
    }

    private static func graphBindings(_ source: GraphSource) throws -> [String: [GraphTarget]] {
        let graph = try GraphAccess(source)
        var result: [String: [Int64: GraphLayer]] = [:]
        for layer in [GraphLayer.stable, .expiredStable] where graph.layers.contains(layer) {
            let rows = try graph.db.cells("""
                SELECT DISTINCT subject,object FROM \(layer.rawValue) WHERE object GLOB 'phPerson:*'
                OR (predicate='nm_hasVisualIdentifier' AND length(object)>=36)
                """)
            for row in rows {
                guard let subject = row[0].integer, let object = row[1].text else { continue }
                let raw = object.hasPrefix("phPerson:") ? String(object.dropFirst("phPerson:".count)) : object
                guard let token = raw.split(separator: "/").first,
                      let uuid = UUID(uuidString: String(token)) else { continue }
                if result[uuid.uuidString]?[subject] == nil {
                    result[uuid.uuidString, default: [:]][subject] = layer
                }
            }
        }
        return result.mapValues { layers in layers.keys.sorted().map { GraphTarget(id:$0,layer:layers[$0] ?? .stable) } }
    }

    private static func clusters(
        _ db: SQLiteDatabase, fields: [String: String], bindings: [String: [GraphTarget]]
    ) throws -> [Cluster] {
        let optional = ["ZPERSONUUID", "ZFULLNAME", "ZDISPLAYNAME", "ZFACECOUNT", "ZVERIFIEDTYPE",
                        "ZDETECTIONTYPE", "ZTYPE", "ZKEYFACE"].map { field in
            fields[field] == nil ? "NULL" : "p." + field
        }.joined(separator: ",")
        let rows = try db.cells("""
            WITH counts AS (
                SELECT ZPERSONFORFACE AS pk,count(*) AS faces,
                       count(DISTINCT CASE WHEN ZASSETFORFACE > 0 THEN ZASSETFORFACE END) AS assets
                FROM ZDETECTEDFACE GROUP BY ZPERSONFORFACE
            )
            SELECT p.Z_PK,\(optional),coalesce(c.faces,0),coalesce(c.assets,0)
            FROM ZPERSON p LEFT JOIN counts c ON c.pk=p.Z_PK
            ORDER BY coalesce(c.faces,0) DESC,p.Z_PK
            """)
        return rows.compactMap { row in
            guard let id = row[0].integer else { return nil }
            let uuid = row[1].text
            let name = [row[2].text, row[3].text].compactMap { $0 }.first { !$0.isEmpty }
            return Cluster(id: id, name: name ?? "Cluster \(id)", uuid: uuid,
                graphTargets: uuid.map { bindings[$0.uppercased(), default: []] } ?? [], isNamed: name != nil,
                faces: row[9].integer ?? 0, photos: row[10].integer ?? 0, cachedCount: row[4].integer,
                verified: row[5].integer, detection: row[6].integer, type: row[7].integer, keyFace: row[8].integer)
        }
    }

    private static func cooccurrence(_ db: SQLiteDatabase) throws -> [Pair] {
        let rows = try db.cells("""
            \(facePresence)
            SELECT a.person,b.person,count(*) FROM present a JOIN present b ON a.asset=b.asset AND a.person<b.person
            GROUP BY 1,2 ORDER BY count(*) DESC,a.person,b.person
            """)
        return rows.compactMap { row in
            guard let a = row[0].integer, let b = row[1].integer, let count = row[2].integer else { return nil }
            return Pair(first: a, second: b, count: count)
        }
    }

    @concurrent
    static func assets(_ source: GraphSource, cluster: Cluster) async throws -> [FaceAsset] {
        try source.withScope {
            let db = try LocalStore.photos.open(source)
            let dbURL = try LocalStore.photos.url(for: source)
            let face = try db.columns(in: "ZDETECTEDFACE")
            let asset = try db.columns(in: "ZASSET")
            let optional = [
                ("f","ZCENTERX",face), ("f","ZCENTERY",face), ("f","ZSIZE",face), ("f","ZQUALITY",face),
                ("a","ZORIENTATION",asset), ("a","ZHIDDEN",asset), ("a","ZTRASHEDSTATE",asset)
            ].map { alias, column, fields in
                fields[column] == nil ? "NULL" : alias + "." + column
            }.joined(separator: ",")
            let rows = try db.cells("""
                SELECT f.Z_PK,a.ZUUID,a.ZDATECREATED,\(optional)
                FROM ZDETECTEDFACE f JOIN ZASSET a ON a.Z_PK=f.ZASSETFORFACE
                WHERE f.ZPERSONFORFACE=? ORDER BY (f.Z_PK=?) DESC,a.ZDATECREATED DESC,f.Z_PK LIMIT 24
                """, [.integer(cluster.id), .integer(cluster.keyFace ?? 0)])
            return rows.compactMap { row in
                guard let id = row[0].integer else { return nil }
                let hidden = (row[8].integer ?? 0) != 0
                let trashed = (row[9].integer ?? 0) != 0
                let path = hidden || trashed ? nil : thumbnail(for: row[1].text, database: dbURL)
                return FaceAsset(id: id, uuid: row[1].text, created: row[2].number.map(Date.init(timeIntervalSinceReferenceDate:)),
                    x: row[3].number, y: row[4].number, size: row[5].number, quality: row[6].number,
                    orientation: row[7].integer ?? 1, hidden: hidden, trashed: trashed, path: path)
            }
        }
    }

    private static func thumbnail(for uuid: String?, database: URL?) -> URL? {
        guard let uuid, let token = UUID(uuidString: uuid)?.uuidString, let first = token.first,
              let parent = database?.deletingLastPathComponent(), parent.lastPathComponent == "database" else { return nil }
        let folder = parent.deletingLastPathComponent().appending(path: "resources/derivatives").resolvingSymlinksInPath()
        for suffix in ["_1_105_c.jpeg", "_1_102_o.jpeg", ".THM"] {
            let url = folder.appending(path: "\(first)/\(token)\(suffix)").resolvingSymlinksInPath()
            guard url.path.hasPrefix(folder.path + "/"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, (1...20_000_000).contains(size) else { continue }
            return url
        }
        return nil
    }

    @concurrent
    static func image(_ path: URL, source: GraphSource) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return source.withScope {
            guard let data = CGImageSourceCreateWithURL(path as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 500
            ]
            return CGImageSourceCreateThumbnailAtIndex(data, 0, options as CFDictionary)
        }
    }
}
