import Foundation
import SQLite3

extension Locale {
    static let iKnow = Locale(identifier: "en_US")
}

enum Page: String, CaseIterable, Identifiable, Sendable {
    case graph, social, kinship, certainty, faces, communications, calendar, identity, retractions, store, apps, consumers

    var id: Self { self }
    var title: String {
        switch self {
        case .graph: "Your Graph"
        case .social: "Social Connections"
        case .kinship: "Kinship"
        case .certainty: "Confidence and Sources"
        case .faces: "People in Photos"
        case .communications: "Communication"
        case .calendar: "Calendar"
        case .identity: "Identities"
        case .retractions: "Retracted Records"
        case .store: "Graph Overview"
        case .apps: "Apps"
        case .consumers: "Derived Stores"
        }
    }

    var subtitle: String {
        switch self {
        case .graph: "Entities, connections, and their underlying records"
        case .social: "Groups, employers, shared events, and social circles"
        case .kinship: "The relationships Apple scored and the values it recorded"
        case .certainty: "Confidence scores, record sources, and how they overlap"
        case .faces: "Face clusters and people who appear together in photos"
        case .communications: "Who communicated, when, and through which apps"
        case .calendar: "Events, participants, and invitations in the graph"
        case .identity: "How the graph links people, contacts, addresses, and other records"
        case .retractions: "Which facts were retracted and what evidence remains"
        case .store: "Classes, layers, and references in the personal graph"
        case .apps: "App identifiers and tokens in the graph"
        case .consumers: "Subscriptions, projections, and companion databases"
        }
    }

    static let graphSymbol = "point.3.connected.trianglepath.dotted"

    var icon: SectionIcon {
        switch self {
        case .graph: .system(Self.graphSymbol)
        case .social: .system("person.2.circle")
        case .kinship: .familyTree
        case .certainty: .system("checkmark.seal")
        case .faces: .system("person.crop.square")
        case .communications: .system("bubble.left.and.bubble.right")
        case .calendar: .system("calendar")
        case .identity: .system("link")
        case .retractions: .system("archivebox")
        case .store: .system("cylinder.split.1x2")
        case .apps: .system("square.grid.2x2")
        case .consumers: .system("rectangle.connected.to.line.below")
        }
    }
}

enum SectionIcon: Sendable {
    case system(String)
    case familyTree
}

enum Cell: Sendable, Hashable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case names([String])
    case empty

    var label: String {
        switch self {
        case .text(let value): value
        case .integer(let value): value.formatted(.number.locale(.iKnow))
        case .real(let value): value.formatted(.number.locale(.iKnow).precision(.fractionLength(0...4)))
        case .names(let values): values.joined(separator: ", ")
        case .empty: "—"
        }
    }

    var number: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .real(let value): value
        default: nil
        }
    }

    var integer: Int64? {
        switch self {
        case .integer(let value): value
        case .text(let value): Int64(value)
        default: nil
        }
    }

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

struct Column: Sendable {
    enum Format: Sendable {
        case automatic, code, layer, score, percent, people
    }

    let title: String
    let sensitive: Bool
    let format: Format

    init(_ title: String, privateValue: Bool = false, format: Format = .automatic) {
        self.title = title
        self.sensitive = privateValue
        self.format = format
    }
}

struct ReportSection: Identifiable, Sendable {
    enum Style: Sendable {
        case table, scores, bars, series, weekly
    }

    let title: String
    let columns: [Column]
    let rows: [[Cell]]
    let style: Style
    let note: String?
    let unavailable: Bool
    let targets: [GraphTarget?]
    let levelColumn: Int?

    var id: String { title }

    init(_ title: String, _ columns: [Column], _ rows: [[Cell]], style: Style = .table,
         note: String? = nil, unavailable: Bool = false, targets: [GraphTarget?] = [], levelColumn: Int? = nil) {
        self.title = title
        self.columns = columns
        self.rows = rows
        self.style = style
        self.note = note
        self.unavailable = unavailable
        self.targets = targets
        self.levelColumn = levelColumn
    }
}

struct Metric: Identifiable, Sendable {
    let title: String
    let value: String

    var id: String { title }

    init(_ title: String, _ value: Int64) {
        self.title = title
        self.value = value.formatted(.number.locale(.iKnow))
    }

    init(_ title: String, text: String) {
        self.title = title
        self.value = text
    }
}

struct GraphTarget: Identifiable, Equatable, Sendable {
    let id: Int64
    var layer: GraphLayer = .stable
}

struct Cluster: Identifiable, Sendable {
    let id: Int64
    let name: String
    let uuid: String?
    let graphTargets: [GraphTarget]
    let isNamed: Bool
    let faces: Int64
    let photos: Int64
    let cachedCount: Int64?
    let verified: Int64?
    let detection: Int64?
    let type: Int64?
    let keyFace: Int64?
}

struct Pair: Identifiable, Sendable {
    struct Key: Hashable, Sendable { let first: Int64; let second: Int64 }
    let first: Int64
    let second: Int64
    let count: Int64
    var id: Key { Key(first: first, second: second) }
}

struct FaceIndex: Sendable {
    let clusters: [Cluster]
    let pairs: [Pair]
}

struct SocialIndex: Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case overview = "Overview"
        case closeness = "Closeness"
        case groups = "Groups"
        case work = "Work"
        case events = "Events"
        case circles = "Circles"
        case chats = "Chats"
        case archive = "Archive"
        var id: Self { self }
    }

    struct Node: Identifiable, Sendable {
        let id: String
        let title: String
        let symbol: String
        let target: GraphTarget?
        let isPerson: Bool
        var role: Role?
    }

    enum Role: Sendable {
        case owner, family, close
    }

    struct Edge: Identifiable, Sendable {
        let first: String
        let second: String
        let label: String
        let weight: Double?
        var sharedCount = 0
        var archived = false
        var evidenceKey = ""
        var kind: Kind?
        var id: String { "\(first)/\(second)/\(label)/\(archived)/\(evidenceKey)" }
    }

    struct Layer: Identifiable, Sendable {
        let id: Kind
        let nodes: [Node]
        let edges: [Edge]
        var overlap: SocialOverlapIndex?
    }

    let layers: [Layer]
}

struct Report: Sendable {
    var metrics: [Metric] = []
    var sections: [ReportSection] = []
    var faces: FaceIndex?
    var social: SocialIndex?
    var tokens: TokenIndex?
    var hasSceneJoin = false
}

extension SQLiteDatabase {
    func cells(_ sql: String, _ bindings: [Parameter] = []) throws -> [[Cell]] {
        try query(sql, bindings) { row in
            (0..<sqlite3_column_count(row)).map { column in
                switch sqlite3_column_type(row, column) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(row, column))
                case SQLITE_FLOAT:
                    Self.number(row, column).map(Cell.real) ?? .empty
                case SQLITE_TEXT: Self.text(row, column).map(Cell.text) ?? .empty
                default: .empty
                }
            }
        }
    }

    func count(_ sql: String) throws -> Int64 {
        try cells(sql).first?.first?.integer ?? 0
    }

    func columns(in table: String) throws -> [String: String] {
        let columns = try cells("SELECT name, type FROM pragma_table_info(?)", [.text(table)])
        var result: [String: String] = [:]
        for row in columns {
            if let name = row[0].text { result[name] = row[1].text ?? "" }
        }
        return result
    }

    func table(_ title: String, _ columns: [Column], _ sql: String,
               bindings: [Parameter] = [], style: ReportSection.Style = .table,
               note: String? = nil) throws -> ReportSection {
        do {
            return try ReportSection(title, columns, cells(sql, bindings), style: style, note: note)
        } catch GraphFailure.schema {
            return ReportSection(title, columns, [], note: "This version of the database lacks the required tables or fields.", unavailable: true)
        }
    }

    static func identifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
