import Foundation

enum LocalStore: String, CaseIterable, Sendable {
    case graph = "graph.db"
    case tagging = "Artifacts/entityTagging/entityTagging.db"
    case features = "Artifacts/feature/features.db"
    case importance = "Artifacts/entityRelevance/entityImportanceSignals.db"
    case interactions = "Artifacts/siri/remembers/view.db"
    case internalViews = "Artifacts/internal/views.db"
    case photos = "Photos.sqlite"
    case calendar = "Calendar.sqlitedb"
    case messages = "chat.db"
    case views = "views.db"
    case global = "globalKnowledge.db"
    case keyValue = "keyvalue.db"

    var filename: String { rawValue.components(separatedBy: "/").last ?? rawValue }

    func url(for source: GraphSource) throws -> URL? {
        if source == .demo { return nil }
        switch self {
        case .graph:
            return source.databaseURL
        case .photos, .calendar, .messages:
            switch source {
            case .mac:
                let home = URL(filePath: NSHomeDirectory())
                switch self {
                case .calendar: return home.appending(path: "Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb")
                case .messages: return home.appending(path: "Library/Messages/chat.db")
                default:
                    let pictures = home.appending(path: "Pictures", directoryHint: .isDirectory)
                    let expected = pictures.appending(path: "Photos Library.photoslibrary/database/Photos.sqlite")
                    if FileManager.default.fileExists(atPath: expected.path) { return expected }
                    let libraries = (try? FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil)) ?? []
                    return libraries
                        .filter { $0.pathExtension == "photoslibrary" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                        .map { $0.appending(path: "database/Photos.sqlite") }
                        .first { FileManager.default.fileExists(atPath: $0.path) } ?? expected
                }
            case .bundle(let root):
                let directory = root.appending(path: "sources", directoryHint: .isDirectory)
                let flat = directory.appending(path: rawValue)
                guard self == .photos, !FileManager.default.fileExists(atPath: flat.path) else { return flat }
                return directory.appending(path: "Photos Library.photoslibrary/database/Photos.sqlite")
            case .demo, .file: throw GraphFailure.missing
            }
        default:
            guard let directory = source.databaseURL?.deletingLastPathComponent() else { throw GraphFailure.missing }
            let nested = directory.appending(path: rawValue)
            let flat = directory.appending(path: rawValue.replacingOccurrences(of: "/", with: "__"))
            return FileManager.default.fileExists(atPath: flat.path) ? flat : nested
        }
    }

    func open(_ source: GraphSource) throws -> SQLiteDatabase {
        let url = try url(for: source)
        if let url { return try SQLiteDatabase(url: url) }
        return try SQLiteDatabase(url: nil, demoSQL: DemoAnalysis.sql(for: self))
    }
}

extension GraphSource {
    func withScope<T>(_ action: () throws -> T) rethrows -> T {
        let scopedURL: URL? = switch self {
        case .bundle(let url), .file(let url): url
        default: nil
        }
        let active = scopedURL?.startAccessingSecurityScopedResource() == true
        defer { if active { scopedURL?.stopAccessingSecurityScopedResource() } }
        return try action()
    }
}

enum AnalysisRepository {
    @concurrent
    static func load(_ page: Page, source: GraphSource) async throws -> Report {
        try source.withScope {
            switch page {
            case .kinship: try KinshipReport.load(source)
            case .communications: try CommunicationsReport.load(source)
            case .faces: try PhotosReport.load(source)
            case .graph: Report()
            default: try GraphReports.load(page, source: source)
            }
        }
    }
}
