import Foundation

enum GraphSource: Hashable, Sendable {
    case demo
    case mac
    case file(URL)
    case bundle(URL)

    var title: String {
        switch self {
        case .demo: "Demo"
        case .mac: "This Mac"
        case .file: "Database Copy"
        case .bundle: "Store Snapshot"
        }
    }

    var databaseURL: URL? {
        switch self {
        case .demo: nil
        case .mac:
            URL(filePath: NSHomeDirectory())
                .appending(path: "Library/IntelligencePlatform/graph.db")
        case .file(let url): url
        case .bundle(let root): root.appending(path: "graph/graph.db")
        }
    }
}

enum GraphLayer: String, CaseIterable, Identifiable, Sendable {
    case stable = "stable_graph"
    case event = "event_graph"
    case expiredStable = "expired_stable_graph"
    case expiredEvent = "expired_event_graph"

    var id: Self { self }

    var title: String {
        switch self {
        case .stable: "Main Graph"
        case .event: "Events"
        case .expiredStable: "Retracted Connections"
        case .expiredEvent: "Retracted Events"
        }
    }
    var symbol: String {
        switch self {
        case .stable: "point.3.connected.trianglepath.dotted"
        case .event: "calendar"
        case .expiredStable: "archivebox"
        case .expiredEvent: "calendar.badge.minus"
        }
    }

}

struct Entity: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let classCode: String?
    let kind: String
    let isOwner: Bool

    var symbol: String {
        if isOwner { return "person.crop.circle.fill" }
        return switch classCode {
        case "SB104": "person"
        case "SB10": "building.2"
        case "SB2": "person.2"
        case "SB152": "mappin"
        case "SB65", "SB472": "calendar"
        case "SB514": "airplane"
        case "SB144": "app"
        default: "circle.dotted"
        }
    }
}

struct Catalog: Sendable {
    static let pageSize = 80

    let layers: [GraphLayer]
    let layer: GraphLayer
    let entities: [Entity]
    let hasNextPage: Bool
}

struct Evidence: Identifiable, Sendable {
    let id: Int64
    let subject: Int64
    let predicate: String
    let predicateLabel: String
    let relationshipID: Int64
    let facet: String?
    let facetLabel: String?
    let value: String?
    let confidence: Double?
    let sources: Int64?
    let sourceRecords: [String]
    let writtenAt: Date?

    var reference: Int64? {
        guard let value, value.hasPrefix("md:"),
              let id = Int64(value.dropFirst(3)), value == "md:\(id)" else { return nil }
        return id
    }

    var sourceLabels: [String] {
        sources.map(Self.sourceLabels(for:)) ?? []
    }

    static let sourceBits = [
        (0, "Contacts"), (1, "Intents"), (5, "Photos"), (8, "Calendar"),
        (10, "Siri Suggested Contacts"), (11, "Siri Suggested Events"),
        (13, "Family Sharing"), (15, "App Catalog")
    ]

    static func sourceLabels(for sources: Int64) -> [String] {
        sourceBits.compactMap { bit, name in
            sources & (1 << bit) == 0 ? nil : name
        }
    }
}

struct Statement: Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case attribute(Int64)
        case relationship(predicate: String, id: Int64)
    }

    let id: ID
    let rows: [Evidence]

    var label: String { rows.first?.predicateLabel ?? "" }
    var code: String { rows.first?.predicate ?? "" }
}

struct Connection: Identifiable, Sendable {
    let id: Int64
    let entity: Entity?
    let layer: GraphLayer?
    let incoming: [Evidence]
    let outgoing: [Evidence]

    var name: String { entity?.name ?? "ID \(id)" }
}

struct GraphDetail: Sendable {
    let entity: Entity
    let statements: [Statement]
    let connections: [Connection]
    let hasMoreStatements: Bool
    let hasMoreConnections: Bool
}
