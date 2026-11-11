import Foundation

extension ParityReports {
    static func photoDetails(_ db: SQLiteDatabase, source: GraphSource) throws -> [ReportSection] {
        var sections: [ReportSection] = []
        if let graph = try? GraphAccess(source) {
            var shapes: [String:Int64] = [:]
            var lengths: [Int:Int64] = [:]
            var scopes: [String:Int64] = [:]
            var identifiers: Set<String> = []
            for layer in graph.layers {
                let rows = try graph.db.cells("""
                    SELECT DISTINCT object FROM \(layer.rawValue)
                    WHERE object GLOB 'phPerson:*' OR (predicate='nm_hasVisualIdentifier' AND instr(object,'/L')>0)
                    """)
                for row in rows {
                    if let raw = row[0].text { identifiers.insert(raw.hasPrefix("phPerson:") ? String(raw.dropFirst(9)) : raw) }
                }
            }
            for identifier in identifiers {
                let chunks = identifier.split(separator:"/",omittingEmptySubsequences:false)
                let valid = chunks.first.flatMap { UUID(uuidString:String($0)) } != nil
                let shape = valid ? "UUID" : "Other Prefix"
                shapes[shape + " · \(max(0,chunks.count-1)) parts after the prefix",default:0] += 1
                lengths[identifier.count,default:0] += 1
                if chunks.count > 1, let scope = chunks.dropFirst().first, scope.wholeMatch(of:/L[0-9]+/) != nil {
                    scopes[String(scope),default:0] += 1
                }
            }
            let columns = [Column("Feature"),Column("Value"),Column("Identifiers")]
            sections.append(ReportSection("Photos Identifier Structure",columns,
                shapes.keys.sorted().map { [.text("Format"),.text($0),.integer(shapes[$0,default:0])] } +
                lengths.keys.sorted().map { [.text("Length"),.integer(Int64($0)),.integer(lengths[$0,default:0])] } +
                scopes.keys.sorted().map { [.text("Scope"),.text($0),.integer(scopes[$0,default:0])] }))
        }
        let fields = try db.columns(in:"ZASSET")
        var geography: [[Cell]] = []
        for (column, limit) in [("ZLATITUDE",90),("ZLONGITUDE",180)] where fields[column] != nil {
            let rows = try db.cells("""
                SELECT count(DISTINCT \(column)),min(\(column)),max(\(column)),
                       count(*)-count(\(column)),coalesce(sum(abs(\(column))>?),0)
                FROM ZASSET
                """,[.integer(Int64(limit))])
            geography += rows.map { [.text(column)] + $0 }
        }
        if fields["ZLOCATIONDATA"] != nil {
            geography += try db.cells("""
                SELECT count(DISTINCT ZLOCATIONDATA),NULL,NULL,count(*)-count(ZLOCATIONDATA),NULL FROM ZASSET
                """).map { [.text("ZLOCATIONDATA")] + $0 }
        }
        sections.append(ReportSection("Geographic Outliers",[
            Column("Field"),Column("Distinct"),Column("Minimum",privateValue:true),
            Column("Maximum",privateValue:true),Column("Empty"),Column("Out of Range")
        ],geography))
        return sections
    }

    @concurrent
    static func scenes(_ source: GraphSource, threshold: Double) async throws -> [ReportSection] {
        try source.withScope {
            let db = try LocalStore.photos.open(source)
            let bounds: [SQLiteDatabase.Parameter] = [.integer(Int64((threshold * 100).rounded()))]
            let joined = try db.table("Scene Classification",[
                Column("Code"),Column("Type"),Column("Rows"),Column("Assets"),Column("Average Score"),Column("Range")
            ], """
                SELECT sc.ZSCENEIDENTIFIER,sc.ZCLASSIFICATIONTYPE,count(*),count(DISTINCT aa.ZASSET),
                       avg(sc.ZCONFIDENCE),CASE WHEN sc.ZSCENEIDENTIFIER>=2147383647 THEN 'Internal' ELSE 'Primary' END
                FROM ZSCENECLASSIFICATION sc JOIN ZMEDIAANALYSISASSETATTRIBUTES aa ON aa.Z_PK=sc.ZASSETATTRIBUTES
                WHERE sc.ZCONFIDENCE>=?/100.0 GROUP BY 1,2 ORDER BY 4 DESC,1,2
                """,bindings:bounds)
            let joins = try db.table("Scene Join Comparison",[
                Column("Join"),Column("Rows"),Column("Assets")
            ], """
                SELECT 'Via Analysis Attributes',count(*),count(DISTINCT aa.ZASSET)
                FROM ZSCENECLASSIFICATION sc JOIN ZMEDIAANALYSISASSETATTRIBUTES aa ON aa.Z_PK=sc.ZASSETATTRIBUTES
                WHERE sc.ZCONFIDENCE>=?/100.0
                UNION ALL
                SELECT 'Direct ID Comparison',count(*),count(DISTINCT a.Z_PK)
                FROM ZSCENECLASSIFICATION sc JOIN ZASSET a ON a.Z_PK=sc.ZASSETATTRIBUTES
                WHERE sc.ZCONFIDENCE>=?/100.0
                """,bindings:bounds+bounds,note:"The correct join uses the analysis attributes.")
            return [joined,joins]
        }
    }
}
