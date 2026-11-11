import Foundation

struct Vocabulary {
    private let classes: [String: String]
    private let predicates: [String: String]

    init(source: GraphSource) {
        let root: URL? = switch source {
        case .demo, .file: nil
        case .bundle(let root): root.appending(path: "ontology")
        case .mac:
            URL(filePath: "/System/Library/PrivateFrameworks/IntelligencePlatformCore.framework/Resources")
        }

        classes = Self.read(root, file: "class", entries: "classes", key: "classId")
        predicates = Self.read(root, file: "predicate", entries: "predicates", key: "predicateId")
    }

    func kind(_ code: String?) -> String {
        guard let code else { return "Entity" }
        return switch code {
        case "SB104": "Person"
        case "SB10": "Organization"
        case "SB2": "Group"
        case "SB152": "Place"
        case "SB65", "SB472": "Event"
        case "SB144": "App"
        default: classes[code] ?? code
        }
    }

    func predicate(_ code: String) -> String {
        switch code {
        case "PS1": "Class"
        case "PS33": "Name"
        case "PS312": "Given Name"
        case "PS441": "Family Name"
        case "PS500": "Employer"
        case "PS45", "demo_organization": "Organization"
        case "PS753", "demo_members": "Group Membership"
        case "PS566": "Group Member"
        case "PS520": "Phone"
        case "PS232": "Participant"
        case "PS29": "Starts"
        case "PS143": "People"
        case "PS406": "Email"
        case "PS407": "Number"
        case "PS740": "Label"
        case "nm_isCurrentUser": "Mac Owner"
        case "nm_bundleID": "App Identifier"
        case "demo_friend": "Acquaintance"
        case "demo_organizer": "Organizer"
        case "demo_place": "Meeting Location"
        default: predicates[code] ?? code
        }
    }

    private static func read(_ root: URL?, file: String, entries: String, key: String) -> [String: String] {
        guard let url = root?.appending(path: file + ".json"),
              let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 * 1024 * 1024),
              let document = try? JSONDecoder().decode([String: [[String: StringValue]]].self, from: data)
        else { return [:] }
        var labels: [String: String] = [:]
        for row in document[entries, default: []] {
            if let id = row[key]?.value, let label = row["label"]?.value {
                labels[id] = label
            }
        }
        return labels
    }

    private struct StringValue: Decodable {
        let value: String?

        init(from decoder: any Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }
}
