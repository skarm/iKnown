import Foundation

extension ParityReports {
    private struct StoreFile {
        let name: String
        let url: URL?
        let demo: LocalStore?

        func open(_ source: GraphSource) throws -> SQLiteDatabase {
            if let demo { return try demo.open(source) }
            guard let url else { throw GraphFailure.missing }
            return try SQLiteDatabase(url:url)
        }

        var isArtifact: Bool { name.hasPrefix("Artifacts/") || name.hasPrefix("Artifacts__") }
    }

    static func storageDetails(_ source: GraphSource, views: SQLiteDatabase) throws -> [ReportSection] {
        var result: [ReportSection] = []
        result.append(try views.table("Biome Streams and Devices", [
            Column("Stream"),Column("Local"),Column("Remote"),Column("Devices"),Column("Updated")
        ], """
            WITH sources AS (
                SELECT sourceIdentifier,modifiedTimestamp,instr(sourceIdentifier,':remotes:') offset
                FROM sourceState WHERE sourceType='biome'
            )
            SELECT CASE WHEN offset>0 THEN substr(sourceIdentifier,1,offset-1) ELSE sourceIdentifier END stream,
                   sum(offset=0),sum(offset>0),
                   count(DISTINCT CASE WHEN offset>0 THEN substr(sourceIdentifier,offset+9) END),
                   datetime(max(modifiedTimestamp)+978307200,'unixepoch')
            FROM sources WHERE sourceIdentifier IS NOT NULL GROUP BY stream ORDER BY 3 DESC,1
            """))
        result.append(try views.table("Biome Subscriptions and Platforms",[
            Column("Stream"),Column("Schedule"),Column("Subscriptions"),Column("Remote Only"),Column("Device Types")
        ], """
            WITH config AS (
                SELECT CASE WHEN json_valid(CAST(config AS TEXT)) THEN CAST(config AS TEXT) ELSE '{}' END document
                FROM viewConfigRecord
            ), listeners AS (
                SELECT j.value value FROM config,json_each(config.document,'$.update.biomeListeners') j
                WHERE j.type='object'
            )
            SELECT json_extract(value,'$.stream'),json_extract(value,'$.schedule'),count(*),
                sum(coalesce(json_extract(value,'$.excludeLocal'),0)),
                group_concat(DISTINCT json_extract(value,'$.syncedDeviceTypes'))
            FROM listeners GROUP BY 1,2 ORDER BY 1,2
            """))
        let owners = try views.cells("""
            SELECT t.tableName,c.name,c.artifactPath,
                   (SELECT count(*) FROM sourceListenerConfig s WHERE s.viewOrderedId=c.id),
                   (SELECT group_concat(DISTINCT s.sourceType) FROM sourceListenerConfig s WHERE s.viewOrderedId=c.id),
                   (SELECT group_concat(DISTINCT s.schedule) FROM sourceListenerConfig s WHERE s.viewOrderedId=c.id)
            FROM viewTables t JOIN viewConfigRecord c ON c.id=t.viewOrderedId
            """)
        let byName = Dictionary(grouping:owners,by: { $0[0].text ?? "" })
        var empty: [[Cell]] = []
        var projections: [[Cell]] = []
        var constants: [[Cell]] = []
        var caches: [[Cell]] = []
        var footprints: [[Cell]] = []
        var zones: [String: [Int64]] = [:]
        var assets: ReportSection?
        var globalTables: [String: String] = [:]
        var feeds: [(String,String,Int64)] = []
        var features: Set<String> = []
        let tripleFields: Set<String> = ["subject","predicate","relationshipId","relationshipPredicate","object"]
        for file in files(source) {
            try Task.checkCancellation()
            guard let db = try? file.open(source) else { continue }
            let tables = try db.cells("""
                SELECT name,type FROM pragma_table_list WHERE schema='main' AND type IN ('table','virtual')
                AND name NOT GLOB 'sqlite_*' AND name<>'grdb_migrations' ORDER BY name
                """)
            for entry in tables {
                guard let table = entry[0].text else { continue }
                let identifier = SQLiteDatabase.identifier(table)
                guard let count = try? db.count("SELECT count(*) FROM \(identifier)") else { continue }
                let fields = try db.columns(in:table)
                let names = Set(fields.keys)
                if file.isArtifact {
                    feeds.append((file.name,table,count))
                    if count == 0 {
                        let owner = byName[table]?.first { row in
                            guard let path = row[2].text else { return false }
                            let nested = path.hasPrefix("Artifacts/") ? path : "Artifacts/" + path
                            let normalized = nested.hasSuffix(".db") ? nested : nested + ".db"
                            return file.name == normalized || file.name == normalized.replacingOccurrences(of:"/",with:"__")
                        }
                        empty.append([.text(file.name),.text(table),owner?[1] ?? .empty,owner?[3] ?? .empty,owner?[4] ?? .empty,owner?[5] ?? .empty])
                    }
                    if tripleFields.isSubset(of:names) {
                        let subjects = try db.count("SELECT count(DISTINCT subject) FROM \(identifier)")
                        let indexes = tables.filter { $0[1].text == "virtual" && ($0[0].text?.hasPrefix(table+"_") ?? false) }
                        let indexRows = indexes.reduce(Int64(0)) { total, index in
                            guard let name = index[0].text else { return total }
                            return total + ((try? db.count("SELECT count(*) FROM \(SQLiteDatabase.identifier(name))")) ?? 0)
                        }
                        projections.append([.text(file.name),.text(table),.integer(count),.integer(subjects),
                                            .integer(Int64(indexes.count)),.integer(indexRows)])
                    }
                    if (1...10_000).contains(count), fields.count <= 40, entry[1].text != "virtual" {
                        for field in fields.keys.sorted() {
                            let column = SQLiteDatabase.identifier(field)
                            let kind = try db.cells("""
                                SELECT CASE WHEN count(\(column))=0 THEN 'NULL'
                                    WHEN sum(CASE WHEN typeof(\(column)) IN ('integer','real') AND \(column)=0 THEN 1 ELSE 0 END)=count(*) THEN '0'
                                    WHEN sum(CASE WHEN typeof(\(column))='text' AND \(column)='' THEN 1 ELSE 0 END)=count(*) THEN 'Empty String'
                                    END FROM \(identifier)
                                """).first?.first?.text
                            if let kind {
                                constants.append([.text(file.name),.text(table),.text(field),.text(kind),.integer(count)])
                            }
                        }
                    }
                    if fields["explanation"] != nil {
                        let values = try db.cells("""
                            WITH docs AS (SELECT CASE WHEN json_valid(CAST(explanation AS TEXT))
                                 THEN CAST(explanation AS TEXT) ELSE '{}' END doc FROM \(identifier)),
                            items AS (
                                 SELECT j.value FROM docs,json_each(doc,'$.positiveContributions') j WHERE j.type='object'
                                 UNION ALL
                                 SELECT j.value FROM docs,json_each(doc,'$.negativeContributions') j WHERE j.type='object'
                            )
                            SELECT DISTINCT json_extract(value,'$.name') FROM items
                            """)
                        features.formUnion(values.compactMap { $0[0].text })
                    }
                }
                if file.name == LocalStore.global.rawValue && (fields["ttlTimestamp"] != nil || fields["assetId"] != nil) {
                    let ttl = fields["ttlTimestamp"] != nil
                    let predicate = fields["predicate"] == nil ? "NULL" : "count(DISTINCT predicate)"
                    let clients = fields["clients"] == nil ? "NULL" : "count(DISTINCT clients)"
                    let first = fields["timestamp"] == nil ? "NULL" : "datetime(min(timestamp)+978307200,'unixepoch')"
                    let last = ttl ? "datetime(max(ttlTimestamp)+978307200,'unixepoch')" : "NULL"
                    let data = try db.cells("SELECT \(predicate),\(clients),\(first),\(last) FROM \(identifier)").first
                        ?? [.empty,.empty,.empty,.empty]
                    let category = ttl ? "Cache with TTL" : "Bundled Data"
                    globalTables[table] = category
                    caches.append([.text(table),.text(category),.integer(count)] + data)
                }
            }
            if file.name == LocalStore.global.rawValue {
                let names = try db.cells("SELECT name,tbl_name FROM sqlite_schema")
                var tableByObject: [String: String] = [:]
                for row in names {
                    if let name = row[0].text, let table = row[1].text { tableByObject[name] = table }
                }
                let tableOrder = globalTables.keys.sorted { $0.count > $1.count }
                if let stats = try? db.cells("SELECT name,count(*),sum(pgsize),sum(ncell) FROM dbstat GROUP BY name ORDER BY 3 DESC") {
                    for row in stats {
                        guard let object = row[0].text else { continue }
                        let base = tableByObject[object] ?? object
                        let prefix = tableOrder.first { base.hasPrefix($0 + "_") || object.hasPrefix("sqlite_autoindex_" + $0 + "_") }
                        let zone = globalTables[base] ?? prefix.flatMap { globalTables[$0] } ?? "Internal Data"
                        footprints.append([row[0], .text(zone), row[1], row[2], row[3]])
                        var totals = zones[zone, default: [0,0,0,0]]
                        totals[0] += 1
                        for (index, value) in row.dropFirst().enumerated() { totals[index + 1] += value.integer ?? 0 }
                        zones[zone] = totals
                    }
                }
                if try !db.columns(in: "static_assets").isEmpty, try !db.columns(in: "static_graph").isEmpty {
                    assets = try db.table("Bundled Knowledge Assets", [
                        Column("Dataset"), Column("Version"), Column("Type"), Column("Rows"), Column("Entities")
                    ], """
                        SELECT a.name,a.version,a.type,count(s.subject),count(DISTINCT s.subject)
                        FROM static_assets a LEFT JOIN static_graph s ON s.assetId=a.id
                        GROUP BY a.id ORDER BY 4 DESC,1
                        """)
                }
            }
        }
        let contexts = Set(features.flatMap { feature in
            feature.split(separator:":",maxSplits:1).dropFirst().flatMap { $0.split(separator:"+").map { $0.trimmingCharacters(in:.whitespaces) } }
        }).filter { !$0.isEmpty }
        let supply: [[Cell]] = contexts.sorted().map { context in
            let entry = feeds.filter { $0.1.lowercased().hasPrefix(context.lowercased()) }.max { $0.2 < $1.2 }
            let using = features.filter { $0.localizedCaseInsensitiveContains(context) }.sorted().joined(separator:", ")
            return [.text(context),entry.map { .text($0.0) } ?? .empty,entry.map { .text($0.1) } ?? .empty,
                    entry.map { .integer($0.2) } ?? .empty,.text(using)]
        }
        result += [
            ReportSection("Graph Projections", [
                Column("File"),Column("Table"),Column("Rows"),Column("Subjects"),Column("FTS Indexes"),Column("FTS Rows")
            ],projections),
            ReportSection("Cache and Bundled Data",[
                Column("Table"),Column("Type"),Column("Rows"),Column("Predicates"),Column("Clients"),
                Column("First Record"),Column("Maximum TTL")
            ],caches),
            ReportSection("Knowledge Store Space Usage", [
                Column("Type"),Column("Objects"),Column("Pages"),Column("Bytes"),Column("Cells")
            ], zones.sorted { $0.value[2] == $1.value[2] ? $0.key < $1.key : $0.value[2] > $1.value[2] }
                .map { [.text($0.key)] + $0.value.map(Cell.integer) }),
            ReportSection("Cache Table and Index Sizes",[
                Column("Object"),Column("Type"),Column("Pages"),Column("Bytes"),Column("Cells")
            ],footprints),
            ReportSection("Empty Artifact Tables",[
                Column("File"),Column("Table"),Column("View"),Column("Subscriptions"),
                Column("Sources"),Column("Schedule")
            ],empty),
            ReportSection("Unpopulated Artifact Fields",[
                Column("File"),Column("Table"),Column("Field"),Column("Value"),Column("Rows")
            ],constants,note:"Tables of up to 10,000 rows and 40 columns were checked."),
            ReportSection("Model Contexts and Their Sources",[
                Column("Context"),Column("File"),Column("Table"),Column("Rows"),Column("Features")
            ],supply)
        ]
        if let assets { result.append(assets) }
        return result
    }

    private static func files(_ source: GraphSource) -> [StoreFile] {
        if source == .demo {
            let stores = LocalStore.allCases.filter { $0.rawValue.hasPrefix("Artifacts/") || $0 == .global }
            return stores.map { StoreFile(name:$0.rawValue,url:nil,demo:$0) }
        }
        if case .file = source { return [] }
        guard let graph = source.databaseURL else { return [] }
        let root = graph.deletingLastPathComponent().resolvingSymlinksInPath()
        let manager = FileManager.default
        let flat = (try? manager.contentsOfDirectory(atPath:root.path)) ?? []
        let artifacts = root.appending(path:"Artifacts",directoryHint:.isDirectory)
        let nested = manager.enumerator(atPath:artifacts.path)?.allObjects.compactMap { $0 as? String } ?? []
        let names = flat + nested.map { "Artifacts/" + $0 }
        return names.sorted().compactMap { name in
            guard name.hasPrefix("Artifacts/") || name.hasPrefix("Artifacts__") || name == LocalStore.global.rawValue else {
                return nil
            }
            let url = root.appending(path:name)
            guard url.pathExtension == "db", !url.lastPathComponent.contains("-fullRebuild"),
                  url.resolvingSymlinksInPath().pathComponents.starts(with:root.pathComponents),
                  (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true else { return nil }
            return StoreFile(name:name,url:url,demo:nil)
        }
    }
}

extension ParityReports {
    static func subscriptionDetails(_ source: GraphSource, views: SQLiteDatabase) throws -> [ReportSection] {
        let listeners = try views.cells("""
            SELECT c.name,s.schedule,CAST(s.config AS TEXT) FROM sourceListenerConfig s
            JOIN viewConfigRecord c ON c.id=s.viewOrderedId
            WHERE s.sourceType='knowledgeGraph' ORDER BY c.name,s.schedule
            """)
        let vocabulary = Vocabulary(source: source)
        var pathViews: [String: Set<String>] = [:]
        let rows: [[Cell]] = listeners.map { row in
            let value = row[2].text.flatMap { try? JSONDecoder().decode(ListenerConfig.self, from: Data($0.utf8)) }
            let filters = value?.filters ?? []
            let paths = Set(filters.flatMap { $0.predicates ?? [] })
            for path in paths { pathViews[path, default: []].insert(row[0].label) }
            let classes = Set(filters.compactMap(\.entityType)).sorted().map { vocabulary.kind($0) }
            let sources = Set(filters.flatMap { $0.sources ?? [] })
            return [row[0],row[1],.text(value?.stores?.joined(separator: ", ") ?? ""),.text(classes.joined(separator: ", ")),
                    .text(paths.sorted().joined(separator: ", ")),.text(sources.sorted().joined(separator: ", "))]
        }
        let pathRows: [[Cell]] = pathViews.sorted { $0.key < $1.key }.map { path, readers in
            let decoded = path.split(separator: "/").map { segment in
                let code = String(segment)
                return code.hasPrefix("SB") ? vocabulary.kind(code) : vocabulary.predicate(code)
            }
            return [.text(path),.text(decoded.joined(separator: " → ")),.integer(Int64(readers.count)),
                    .text(readers.sorted().joined(separator: ", "))]
        }
        var result = [
            ReportSection("Graph Subscription Filters", [
                Column("View"), Column("Schedule"), Column("Stores"), Column("Classes"),
                Column("Paths"), Column("Sources")
            ],rows),
            ReportSection("Predicate Paths in Subscriptions", [
                Column("Path"), Column("Decoded Path"), Column("Views"), Column("Subscribers")
            ],pathRows)
        ]
        if let graph = try? GraphAccess(source) {
            var consumers: [String: Set<String>] = [:]
            for (path, readers) in pathViews {
                for part in path.split(separator: "/") where part.hasPrefix("PS") || part.hasPrefix("nm_") {
                    consumers[String(part), default: []].formUnion(readers)
                }
            }
            var totals: [String: [Int64]] = [:]
            for layer in graph.layers where !consumers.isEmpty {
                let index = layer == .stable || layer == .event ? 0 : 1
                let counts = try graph.db.cells("""
                    SELECT predicate,count(*) FROM \(layer.rawValue) GROUP BY predicate
                    UNION ALL
                    SELECT relationshipPredicate,count(*) FROM \(layer.rawValue)
                    WHERE nullif(relationshipPredicate,'') IS NOT NULL AND relationshipPredicate<>predicate
                    GROUP BY relationshipPredicate
                    """)
                for row in counts {
                    guard let code = row[0].text, consumers[code] != nil, let count = row[1].integer else { continue }
                    totals[code, default: [0,0]][index] += count
                }
            }
            let measured: [[Cell]] = consumers.sorted { lhs, rhs in
                let a = totals[lhs.key, default: [0,0]][0], b = totals[rhs.key, default: [0,0]][0]
                return a == b ? lhs.key < rhs.key : a > b
            }.map { code, readers in
                [.text(code),.text(vocabulary.predicate(code)),.integer(Int64(readers.count))]
                    + totals[code, default: [0,0]].map(Cell.integer)
            }
            result.append(ReportSection("Records for Subscribed Predicates", [
                Column("Predicate"), Column("Decoded Path"), Column("Views"), Column("Active"), Column("Retracted")
            ],measured))
        }
        let fields = try views.columns(in: "sourceListenerState")
        if fields["sourceUpdatedTimestamp"] != nil {
            let bookmark = fields["bookmark"] == nil ? "NULL" : "sum(bookmark IS NOT NULL)"
            let pending = fields["runByTimestamp"] == nil ? "NULL" : "sum(runByTimestamp>0)"
            result.append(try views.table("Subscription Activity", [
                Column("States"), Column("Received Updates"), Column("No Updates"), Column("Bookmarks"),
                Column("Pending"), Column("Last Update")
            ], """
                SELECT count(*),sum(sourceUpdatedTimestamp>0),sum(coalesce(sourceUpdatedTimestamp,0)<=0),
                       \(bookmark),\(pending),datetime(nullif(max(sourceUpdatedTimestamp),0)+978307200,'unixepoch')
                FROM sourceListenerState
                """))
            let config = try views.columns(in: "sourceListenerConfig")
            if fields["sourceListenerConfigId"] != nil, config["sourceListenerConfigId"] != nil {
                result.append(try views.table("Subscriptions Without Updates", [
                    Column("View"), Column("Source"), Column("Schedule"), Column("Subscriptions")
                ], """
                    SELECT c.name,s.sourceType,s.schedule,count(*) FROM sourceListenerState l
                    JOIN sourceListenerConfig s ON l.sourceListenerConfigId=s.sourceListenerConfigId
                    JOIN viewConfigRecord c ON c.id=s.viewOrderedId WHERE coalesce(l.sourceUpdatedTimestamp,0)<=0
                    GROUP BY 1,2,3 ORDER BY 4 DESC,1,2
                    """))
            }
        }
        return result
    }

    private struct ListenerConfig: Decodable {
        let stores: [String]?
        let filters: [Filter]?

        struct Filter: Decodable {
            let entityType: String?
            let predicates: [String]?
            let sources: [String]?
        }
    }
}
