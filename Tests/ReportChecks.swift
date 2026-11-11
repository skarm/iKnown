import Foundation
import ImageIO
import UniformTypeIdentifiers
import SQLite3

final class FeatureFixture: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    private let value: NSNumber

    init(_ value: Bool) { self.value = NSNumber(value: value) }

    required init?(coder: NSCoder) {
        guard let value = coder.decodeObject(of: NSNumber.self, forKey: "value") else { return nil }
        self.value = value
    }

    func encode(with coder: NSCoder) {
        coder.encode(value, forKey: "value")
    }
}

@main
struct ReportChecks {
    static func main() async throws {
        precondition(Cell.integer(1_200).label == "1,200")
        precondition(Cell.real(0.25).label == "0.25")
        let root = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        for store in LocalStore.allCases {
            let url = try store.url(for: .bundle(root))!
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fixture = DemoAnalysis.sql(for: store)
            precondition(!fixture.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) },
                         "\(store.rawValue) contains untranslated demo text")
            try seed(url, sql: fixture)
        }

        try transitiveSocialComponent()
        let snapshot = GraphSource.bundle(root)
        for source in [GraphSource.demo, snapshot] {
            let cards = try await AnalysisRepository.home(source)
            precondition(cards.first { $0.page == .communications }?.value == .integer(850))
            precondition(cards.first { $0.page == .communications }?.rows.isEmpty == false)
            precondition(cards.first { $0.page == .faces }?.faceIndex?.clusters.count == 8)
            precondition(cards.first { $0.page == .identity }?.rows.contains { $0.target?.id == 9_007_199_254_740_993 } == true)
            let upcoming = cards.first { $0.page == .calendar }
            precondition(upcoming?.rows.map { $0.target?.id } == [101,104,105])
            let overview = try await AnalysisRepository.homeSocial(source)?.layers.first
            precondition(overview?.id == .overview)
            precondition(overview?.nodes.contains { $0.role == .owner } == true)
            precondition(overview?.edges.contains { $0.kind == .work } == true)
            let low = try await ParityReports.scenes(source,threshold:0.5)
            let high = try await ParityReports.scenes(source,threshold:0.99)
            precondition(low[0].rows.reduce(0) { $0 + ($1[2].integer ?? 0) } >
                         high[0].rows.reduce(0) { $0 + ($1[2].integer ?? 0) })
            precondition((low[1].rows.first?[1].integer ?? 0) > 0 && low[1].rows.last?[1].integer == 0)
            for page in Page.allCases where page != .graph {
                let report: Report
                do {
                    report = try await AnalysisRepository.load(page, source: source)
                } catch {
                    print("\(source.title) / \(page.title): \(error)")
                    exit(1)
                }
                precondition(!report.metrics.isEmpty, "\(page.rawValue) has no metrics")
                precondition(report.sections.contains { !$0.rows.isEmpty }, "\(page.rawValue) has no rows")
                for section in report.sections {
                    precondition(!section.unavailable, "\(page.rawValue): \(section.title) has no schema")
                    precondition(section.rows.allSatisfy { $0.count == section.columns.count }, section.title)
                    precondition(section.targets.isEmpty || section.targets.count == section.rows.count, section.title)
                }
                if page == .kinship {
                    let flags = report.sections.first { $0.title == "Corroborating Features" }
                    let row = flags?.rows.first { $0[0].text == "Archived Contact" }
                    precondition(row?.suffix(2) == [.text("Archive"),.text("Archive")])
                    precondition(report.sections.contains { $0.title == "Composite Score Breakdown Checks" && !$0.rows.isEmpty })
                    let ledger = report.sections.first { $0.title == "Classifier Features" }
                    precondition(ledger?.rows.first { $0[0].text == "sharedAddress" }?[1...3] ==
                                 [.integer(2), .integer(1), .integer(1)])
                } else if page == .communications {
                    let directions = report.sections.first { $0.title == "How Direction Was Inferred" }?.rows
                    precondition(directions?.first?[0].integer == 3)
                    precondition((directions?.first?[2].integer ?? 0) > 0)
                    precondition(report.metrics.first?.value == Int64(850).formatted(.number.locale(.iKnow)))
                    let peak = report.sections.first { $0.title == "Largest Monthly Increase in Activity" }?.rows.first
                    precondition((peak?[4].integer ?? 0) > 0)
                    precondition(peak?[4].integer == (peak?[2].integer ?? 0) - (peak?[3].integer ?? 0))
                } else if page == .social {
                    try socialEvidence(report, source: source)
                } else if page == .calendar {
                    let legs = report.sections.first { $0.title == "Flights from Reservations" }
                    precondition(legs?.targets.first == GraphTarget(id: 105, layer: .event))
                    precondition(legs?.rows.first?[4...5] == [.text("Berlin Brandenburg Airport · BER"), .text("Charles de Gaulle Airport · CDG")])
                    let coverage = report.sections.first { $0.title == "Calendar Source Coverage" }
                    precondition(coverage?.rows.first?.prefix(2) == [.integer(2), .integer(1)])
                    let rhythm = report.sections.first { $0.title == "Event Start Times by Hour" }
                    precondition(rhythm?.rows[18][1] == .integer(1))
                    let domains = report.sections.first { $0.title == "Invitation Domains" }
                    precondition(domains?.rows.first == [.text("example.test"),.integer(1),.integer(2),.integer(1),.integer(0),.integer(0)])
                    let repeatSeries = report.sections.first { $0.title == "Recurring Meetings" }
                    precondition(repeatSeries?.rows.first?[1] == .integer(2))
                } else if page == .identity {
                    let cards = report.sections.first { $0.title == "Identity Cards" }
                    precondition(cards?.targets.contains { $0?.id == 2 } == true)
                    precondition(report.sections.contains { $0.title == "Identity Resolution Funnel" && !$0.rows.isEmpty })
                } else if page == .store {
                    let examples = report.sections.first { $0.title == "Two Examples from the Graph" }
                    precondition(examples?.targets.count == 2)
                } else if page == .certainty {
                    let dossier = report.sections.first { $0.title == "Confidence Examples" }
                    precondition(dossier?.levelColumn == 1 && dossier?.targets.first != nil)
                } else if page == .retractions {
                    let edges = report.social?.layers.first?.edges ?? []
                    precondition(edges.contains { $0.archived && $0.first == "entity-16" && $0.second == "event-101" })
                    precondition(!edges.contains { $0.archived && $0.first == "event-101" && $0.second == "entity-7" })
                } else if page == .apps {
                    let token = "lsBundleRecord:" + GraphReports.digest("com.apple.Notes")
                    precondition(report.tokens?.words[TokenIndex.bare(token)] == ["com.apple.Notes"])
                } else if page == .consumers {
                    let contexts = report.sections.first { $0.title == "Model Contexts and Their Sources" }
                    precondition(contexts?.rows.first?[2] == .text("WifiContextEvents"), "\(source.title): \(String(describing:contexts?.rows))")
                    precondition(contexts?.rows.first?[3] == .integer(0))
                    let biome = report.sections.first { $0.title == "Biome Streams and Devices" }
                    precondition(biome?.rows.first?[1...3] == [.integer(1),.integer(1),.integer(1)])
                    precondition(report.sections.contains { $0.title == "Graph Projections" && !$0.rows.isEmpty })
                    let asset = report.sections.first { $0.title == "Bundled Knowledge Assets" }
                    precondition(asset?.rows.first?.suffix(2) == [.integer(3), .integer(2)])
                    let paths = report.sections.first { $0.title == "Records for Subscribed Predicates" }
                    precondition(paths?.rows.contains { $0[0] == .text("nm_bundleID") && ($0[3].integer ?? 0) > 0 } == true)
                } else if page == .faces {
                    let memories = report.sections.first { $0.title == "Memories Engagement" }
                    precondition(memories?.rows.first == [4,3,5,2,3,2,1,1,2].map(Cell.integer))
                    let curated = report.sections.first { $0.title == "Assets in Memories" }
                    precondition(curated?.rows.first == [.integer(3), .integer(2), .integer(2)])
                    let index = report.faces!
                    precondition(index.clusters.count == 8)
                    precondition(!index.pairs.isEmpty)
                    let owner = index.clusters.first { $0.id == 1 }!
                    precondition(owner.graphTargets.contains { $0.id == 9_007_199_254_740_993 })
                    let assets = try await PhotosReport.assets(source, cluster: owner)
                    precondition(!assets.isEmpty && assets.count <= 24 && assets[0].point != nil)
                }
            }
        }

        let selected = try await GraphRepository.catalog(source: snapshot, requestedLayer: .stable, search: "brooks", page: 0)
        precondition(selected.entities.map(\.id) == [12])
        let owner = try await GraphRepository.detail(source: snapshot, layer: .stable, id: 9_007_199_254_740_993)
        precondition(owner?.entity.isOwner == true)
        precondition(owner?.connections.first { $0.id == 2 }?.incoming.isEmpty == false)

        let features = try LocalStore.features.url(for: snapshot)!
        let yes = try NSKeyedArchiver.archivedData(withRootObject: FeatureFixture(true), requiringSecureCoding: true)
        let no = try NSKeyedArchiver.archivedData(withRootObject: FeatureFixture(false), requiringSecureCoding: true)
        try seed(features, sql: """
            INSERT INTO kv VALUES ('personEntityTaggingFacts','archived','2',x'\(hex(yes))'),
                ('personEntityTaggingFacts','archived','4',x'\(hex(no))'),
                ('personEntityTaggingFacts','archived','7',x'00010203');
            """)
        let kinship = try await AnalysisRepository.load(.kinship, source: snapshot)
        let archive = kinship.sections.first { $0.title == "Classifier Features" }?.rows.first { $0[0].text == "archived" }
        precondition(archive == [.text("archived"),.integer(3),.integer(1),.integer(1),.integer(0),.integer(1)])

        let photoReport = try await AnalysisRepository.load(.faces, source:snapshot)
        let cluster = photoReport.faces!.clusters.first { $0.id == 1 }!
        let photoAssets = try await PhotosReport.assets(snapshot, cluster:cluster)
        let asset = photoAssets.first { !$0.hidden && !$0.trashed && $0.uuid != nil }!
        let uuid = UUID(uuidString:asset.uuid!)!.uuidString
        let photosURL = try LocalStore.photos.url(for:snapshot)!
        let folder = photosURL.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path:"resources/derivatives/\(uuid.prefix(1))")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let previewURL = folder.appending(path:uuid + "_1_105_c.jpeg")
        let canvas = CGContext(data:nil,width:8,height:8,bitsPerComponent:8,bytesPerRow:32,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(red:0.2,green:0.4,blue:0.7,alpha:1)
        canvas.fill(CGRect(x:0,y:0,width:8,height:8))
        let destination = CGImageDestinationCreateWithURL(previewURL as CFURL,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,canvas.makeImage()!,nil)
        precondition(CGImageDestinationFinalize(destination))
        let preview = try await PhotosReport.assets(snapshot, cluster:cluster).first { $0.id == asset.id }?.path
        precondition(preview != nil)
        let image = await PhotosReport.image(preview!,source:snapshot)
        precondition(image?.width == 8)

        try seed(photosURL, sql: """
            INSERT INTO ZASSET (Z_PK, ZDATECREATED, ZKIND) VALUES
                (80000, unixepoch('2032-02-01T00:00:00Z')-978307200, 0),
                (80001, unixepoch('2032-02-29T23:59:59Z')-978307200, 0);
            INSERT INTO ZDETECTEDFACE (ZPERSONFORFACE, ZASSETFORFACE) VALUES
                (1,0), (2,0), (1,80000), (80000,80000), (1,80001);
            INSERT INTO ZDETECTEDFACE (ZPERSONFORFACE, ZASSETFORFACE)
                SELECT ZPERSONFORFACE, ZASSETFORFACE FROM ZDETECTEDFACE ORDER BY Z_PK LIMIT 1;
            """)
        let updatedPhotos = try await AnalysisRepository.load(.faces, source: snapshot)
        let sharedMetric = "Shared Photos"
        precondition(updatedPhotos.metrics.first { $0.title == sharedMetric }?.value ==
                     photoReport.metrics.first { $0.title == sharedMetric }?.value)
        let originalPairs = photoReport.faces!.pairs.map { [$0.first, $0.second, $0.count] }
        precondition(updatedPhotos.faces!.pairs.map { [$0.first, $0.second, $0.count] } == originalPairs)
        for title in ["Photos with Faces by Month", "Photos and Videos by Month"] {
            let month = updatedPhotos.sections.first { $0.title == title }?.rows.first { $0[0] == .text("2032-02") }
            precondition(month?[1] == .integer(2), title)
        }

        let eventOnlyURL = root.appending(path: "Events.db")
        try seed(eventOnlyURL, sql: """
            CREATE TABLE event_graph (subject INTEGER NOT NULL, predicate TEXT NOT NULL, relationshipId INTEGER DEFAULT 0,
                relationshipPredicate TEXT DEFAULT '', object TEXT, confidence REAL, sources INTEGER,
                sourceDuplicates TEXT, timestamp REAL);
            INSERT INTO event_graph (subject, predicate, object, confidence) VALUES (42, 'PS33', 'Fixture Event', 1);
            """)
        let eventOnly = GraphSource.file(eventOnlyURL)
        let eventCatalog = try await GraphRepository.catalog(source: eventOnly, requestedLayer: .stable, search: "", page: 0)
        precondition(eventCatalog.layers == [.event] && eventCatalog.layer == .event && eventCatalog.entities.map(\.id) == [42])
        let eventDetail = try await GraphRepository.detail(source: eventOnly, layer: .event, id: 42)
        precondition(eventDetail?.entity.name == "Fixture Event" && eventDetail?.statements.count == 1)

        let graphURL = snapshot.databaseURL!
        var writer: OpaquePointer?
        precondition(sqlite3_open(graphURL.path(percentEncoded:false),&writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        precondition(sqlite3_exec(writer, """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            INSERT INTO stable_graph (subject,predicate,object,confidence) VALUES (999,'PS33','From WAL',1);
            INSERT INTO stable_graph (subject,predicate,object,confidence)
                VALUES (1000,'PS33','Before NUL' || char(0) || 'Après le séparateur',1);
            """,nil,nil,nil) == SQLITE_OK)
        let wal = try await GraphRepository.catalog(source:snapshot,requestedLayer:.stable,search:"from wal",page:0)
        precondition(wal.entities.map(\.id) == [999])
        let suffix = try await GraphRepository.catalog(source: snapshot, requestedLayer: .stable, search: "apres le separateur", page: 0)
        precondition(suffix.entities.map(\.id) == [1000])

        let reader = try LocalStore.graph.open(snapshot)
        let embeddedNUL = "before\0after"
        let boundText = try reader.cells("SELECT ?", [.text(embeddedNUL)])
        precondition(boundText == [[.text(embeddedNUL)]])
        do {
            _ = try reader.cells("SELECT ?")
            fatalError("A statement silently accepted a missing binding")
        } catch GraphFailure.schema {}
        do {
            _ = try reader.cells("DELETE FROM stable_graph")
            fatalError("A read-only handle accepted a write")
        } catch GraphFailure.unreadable {
            // SQLITE_READONLY is normalized at the storage boundary.
        }
        do {
            _ = try await AnalysisRepository.load(.faces, source: .file(snapshot.databaseURL!))
            fatalError("A single graph copy unexpectedly found a Photos library")
        } catch GraphFailure.missing {
            // Optional stores require an explicit snapshot or live source.
        }

        print("Checked 12 sections against in-memory and on-disk SQLite, the dashboard, social evidence, Calendar, Photos, subscriptions and cache, WAL reads, and write protection.")
    }

    private static func socialEvidence(_ report: Report, source: GraphSource) throws {
        let invitations = report.sections.first { $0.title == "Shared Event Invitations" }!
        precondition(invitations.rows.map { $0[1].text } == ["2027-01-12", "2027-02-12"])
        for row in invitations.rows {
            guard case .names(let names) = row[3] else { fatalError("Expected a participant list") }
            precondition(row[2] == .integer(Int64(names.count)))
        }

        let layers = report.social!.layers
        let circles = layers.first { $0.id == .circles }!
        let evidence = try circles.overlap!.sections(in: circles, anchor: "person-7",
            edges: circles.edges.filter { ($0.weight ?? 0) >= 0.5 })
        let shared = evidence.first { $0.title == "Events Shared by All Members" }!
        precondition(shared.targets == [GraphTarget(id: 104, layer: .event)])
        precondition(shared.rows.first?[1] == .text("2027-02-12"))

        let groups = layers.first { $0.id == .groups }!
        let club = groups.nodes.first { $0.id == "host-6" }!
        let rows = try SocialStatements.load(source, kind: .groups, node: club).first!.rows
        precondition(rows.count == 3 && rows.allSatisfy { $0[5] == .integer(2) && $0[6] == .text("Intents") })

        let chats = layers.first { $0.id == .chats }!
        let first = chats.nodes.first!
        precondition(chats.edges.first?.sharedCount == 3)
        let connected = try chats.overlap!.sections(in: chats, anchor: first.id,
            edges: chats.edges.filter { $0.sharedCount >= 2 })
        let separate = try chats.overlap!.sections(in: chats, anchor: first.id,
            edges: chats.edges.filter { $0.sharedCount >= 4 })
        precondition(connected.first?.rows.first?[0] == .integer(2))
        precondition(separate.first?.rows.first?[0] == .integer(1))
        let activity = try SocialStatements.chatTraffic(source, chatID: Int64(first.id)!)
        precondition(activity.rows.contains { ($0[3].integer ?? 0) > 0 && ($0[4].integer ?? 0) > 0 })
    }

    private static func transitiveSocialComponent() throws {
        let nodes = ["a", "b", "c"].map {
            SocialIndex.Node(id: $0, title: $0, symbol: "person", target: nil, isPerson: true)
        }
        let edges = [
            SocialIndex.Edge(first: "a", second: "b", label: "", weight: 0.5),
            SocialIndex.Edge(first: "b", second: "c", label: "", weight: 0.5)
        ]
        let layer = SocialIndex.Layer(id: .circles, nodes: nodes, edges: edges)
        let index = SocialOverlapIndex(memberships: ["a": ["first"], "b": ["first", "second"], "c": ["second"]], items: [:])
        let sections = try index.sections(in: layer, anchor: "a", edges: edges)
        precondition(sections.first?.rows.first?.prefix(5) == [.integer(3), .integer(2), .integer(3), .real(2.0/3), .real(0)])
        let pairs = sections.first { $0.title == "All Pairs in the Component" }!
        precondition(pairs.rows.contains { $0[0...5] == [.text("a"), .text("c"), .integer(0), .integer(2), .real(0), .text("Below Threshold")] })
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format:"%02x",$0) }.joined()
    }

    private static func seed(_ url: URL, sql: String) throws {
        var connection: OpaquePointer?
        precondition(sqlite3_open(url.path(percentEncoded: false), &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        precondition(result == SQLITE_OK, message.map { String(cString: $0) } ?? "Fixture SQLite error")
    }
}
