import Foundation

struct TokenIndex: Sendable {
    let words: [String: [String]]
    static let spaces: Set<String> = ["lsBundleRecord","ekEvent","sgEvent","sgContact","inPerson","faFamilyCircle","phPerson"]

    static func bare(_ input: String) -> String {
        let value = input.trimmingCharacters(in:.whitespacesAndNewlines)
        let tail = value.split(separator:":",maxSplits:1)
        let token = tail.count == 2 && spaces.contains(String(tail[0])) ? String(tail[1]) : value
        return String(token.reversed().drop(while: { $0 == "=" }).reversed())
    }

    static func load(_ graph: GraphAccess) throws -> (TokenIndex, ReportSection) {
        var vocabulary: Set<String> = []
        var occurrences: [String: [String]] = [:]
        for layer in graph.layers {
            let rows = try graph.db.cells("SELECT DISTINCT subject,object FROM \(layer.rawValue)")
            for row in rows {
                if let id = row[0].integer { vocabulary.insert(String(id)) }
                guard let object = row[1].text else { continue }
                let pieces = object.split(separator:":",maxSplits:1)
                if pieces.count == 2, spaces.contains(String(pieces[0])) {
                    occurrences[String(pieces[0]),default:[]].append(String(pieces[1]))
                } else {
                    vocabulary.insert(object)
                }
            }
        }
        var words: [String:[String]] = [:]
        for word in vocabulary.sorted() {
            try Task.checkCancellation()
            words[bare(GraphReports.digest(word)),default:[]].append(word)
        }
        let rows: [[Cell]] = occurrences.keys.sorted().map { space in
            let all = occurrences[space,default:[]]
            let distinct = Set(all)
            let digestCount = distinct.filter { token in
                let stripped = bare(token)
                let padded = stripped + String(repeating:"=",count:(4-stripped.utf8.count%4)%4)
                return Data(base64Encoded:padded)?.count == 32
            }.count
            return [.text(space),.integer(Int64(all.count)),.integer(Int64(distinct.count)),
                .integer(Int64(digestCount)),.integer(Int64(distinct.filter { words[bare($0)] != nil }.count))]
        }
        return (TokenIndex(words:words),ReportSection("Token Namespaces", [
            Column("Namespace"),Column("Records"),Column("Distinct"),Column("32-Byte Base64"),Column("Source Found")
        ],rows,note:"Only values and IDs in the open graph are checked. Matches are verified using SHA-256."))
    }
}
