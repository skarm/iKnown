import Foundation
import SQLite3

enum BiomeInventory {
    struct App {
        let bundle: String
        let name: String?
        let version: String?
    }

    static func apps(_ source: GraphSource) throws -> [App] {
        let root: URL
        switch source {
        case .mac:
            root = URL(filePath:NSHomeDirectory()).appending(path:"Library/Biome/sets/Default")
        case .bundle(let folder): root = folder.appending(path:"biome")
        default: return []
        }
        let db = try SQLiteDatabase(url:root.appending(path:"App.InstalledApp/Database/Set.db"))
        let items: [App?] = try db.query("""
            SELECT m.metacontent,c.content FROM metacontent_provenance p
            JOIN metacontent m ON m.instance_hash=p.instance_hash
            LEFT JOIN content c ON c.content_hash=p.content_hash
            WHERE p.deleted_run_length=0 ORDER BY p.sequence_number
            """) { row in
                let meta = strings(row,0)
                let content = strings(row,1)
                guard let bundle = content[1] ?? meta[1], !bundle.isEmpty else { return nil }
                return App(bundle:bundle,name:content[3],version:meta[2])
            }
        return items.compactMap { $0 }
    }

    private static func strings(_ row: OpaquePointer, _ column: Int32) -> [UInt64:String] {
        let count = Int(sqlite3_column_bytes(row,column))
        guard (1...1_048_576).contains(count), let data = sqlite3_column_blob(row,column) else { return [:] }
        let bytes = UnsafeRawBufferPointer(start:data,count:count)
        var i = 0
        var fields: [UInt64:String] = [:]
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from:0,through:63,by:7) {
                guard i < count else { return nil }
                let byte = bytes[i]
                i += 1
                guard shift != 63 || byte <= 1 else { return nil }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            return nil
        }
        while i < count {
            guard let key = varint(), key>>3 != 0 else { return [:] }
            switch key & 7 {
            case 0: guard varint() != nil else { return [:] }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let length = varint(), length <= UInt64(count-i) else { return [:] }
                let end = i + Int(length)
                let field = key >> 3
                if fields[field] == nil { fields[field] = String(bytes:bytes[i..<end],encoding:.utf8) }
                i = end
            default: return [:]
            }
            guard i <= count else { return [:] }
        }
        return fields
    }
}
