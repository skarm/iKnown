import Foundation

extension GraphAccess {
    func provenanceEvidence() throws -> [ReportSection] {
        var referenceCounts: [Int: Int64] = [:]
        var namespaceRows: [String: Int64] = [:]
        var namespaceRecords: [String: Set<String>] = [:]
        var singleSource: [Int64: [String: Int64]] = [:]
        var masks: [Int64: Int64] = [:]
        var liveMasks: [Int64: Int64] = [:]
        var modes: [Int64: [Cell: Int64]] = [:]
        for layer in layers {
            let live = layer == .stable || layer == .event
            let grouped = try db.cells("""
                SELECT sources,confidence,count(*) FROM \(layer.rawValue) GROUP BY sources,confidence
                """)
            for row in grouped {
                guard let mask = row[0].integer, let count = row[2].integer else { continue }
                masks[mask, default: 0] += count
                if live {
                    liveMasks[mask, default: 0] += count
                    for bit in Evidence.sourceBits {
                        let key: Int64 = 1 << bit.0
                        if mask & key != 0 { modes[key, default: [:]][row[1], default: 0] += count }
                    }
                }
            }
            _ = try db.query("""
                SELECT sources,sourceDuplicates FROM \(layer.rawValue)
                """) { row in
                let source = SQLiteDatabase.integer(row, 0) ?? 0
                let refs = (SQLiteDatabase.text(row, 1) ?? "").split(separator: "\u{1e}")
                referenceCounts[refs.count, default: 0] += 1
                var namespaces: Set<String> = []
                for ref in refs {
                    let prefix = ref.firstIndex(of: ":").map { String(ref[..<$0]) } ?? "No Prefix"
                    namespaces.insert(prefix)
                    namespaceRecords[prefix, default: []].insert(String(ref))
                }
                for namespace in namespaces {
                    namespaceRows[namespace, default: 0] += 1
                    if source != 0, source.nonzeroBitCount == 1 {
                        singleSource[source, default: [:]][namespace, default: 0] += 1
                    }
                }
            }
        }
        let sourceRows: [[Cell]] = Evidence.sourceBits.map { bit, name in
            let mask: Int64 = 1 << bit
            let total = liveMasks.reduce(Int64(0)) { $0 + ($1.key & mask != 0 ? $1.value : 0) }
            let exact = liveMasks[mask, default: 0]
            let mode = modes[mask]?.sorted {
                $0.value == $1.value ? ($0.key.number ?? -1) > ($1.key.number ?? -1) : $0.value > $1.value
            }.first
            let share = total == 0 ? Cell.empty : .real(Double(mode?.value ?? 0) / Double(total))
            return [.text(name),.integer(mask),.integer(total),.integer(exact),.integer(total - exact),mode?.key ?? .empty,share]
        }
        let proof = Evidence.sourceBits.flatMap { bit, name -> [[Cell]] in
            let mask: Int64 = 1 << bit
            let total = masks.reduce(Int64(0)) { $0 + ($1.key & mask != 0 ? $1.value : 0) }
            return singleSource[mask, default: [:]].sorted { $0.key < $1.key }.map { namespace, count in
                [.text(name),.text(namespace),.integer(count),.integer(namespaceRows[namespace, default: 0]),.integer(total)]
            }
        }
        let knownMask = Evidence.sourceBits.reduce(Int64(0)) { $0 | (1 << $1.0) }
        var result = [
            ReportSection("Contribution of Each Source Bit", [
                Column("Source"),Column("Mask"),Column("Active"),Column("This Bit Only"),Column("In Combinations"),
                Column("Most Common Confidence"),Column("Share")
            ], sourceRows),
            ReportSection("Source Bits and Original Records", [
                Column("Source"),Column("Namespace"),Column("Rows with One Bit"),Column("Total in Namespace"),
                Column("Total with Bit")
            ], proof),
            ReportSection("sourceDuplicates Namespaces", [
                Column("Namespace"),Column("Rows"),Column("Distinct References")
            ], namespaceRows.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { [.text($0.key),.integer($0.value),.integer(Int64(namespaceRecords[$0.key, default: []].count))] }),
            ReportSection("Source References per Record", [Column("References"),Column("Rows")],
                referenceCounts.sorted { $0.key < $1.key }.map { [.integer(Int64($0.key)),.integer($0.value)] }, style: .bars),
            ReportSection("Masks with Unknown Bits", [Column("Mask"),Column("Unknown Bits"),Column("Rows")],
                masks.filter { $0.key == 0 || $0.key & ~knownMask != 0 }.sorted { $0.key < $1.key }.map {
                    [.text(String(format: "0x%llX", $0.key)),.text(String(format: "0x%llX", $0.key & ~knownMask)),.integer($0.value)]
                })
        ]
        let phases = try db.columns(in: "phase_status")
        if phases["source"] != nil, phases["status"] != nil {
            let rows = try db.cells("SELECT source,status FROM phase_status ORDER BY source")
            result.append(ReportSection("Source Loading Status", [
                Column("Source"),Column("Status"),Column("Active Records")
            ], rows.map { row in
                let count = row[0].integer.flatMap { source -> Int64? in
                    guard (1...64).contains(source) else { return nil }
                    let mask: Int64 = 1 << (source - 1)
                    return liveMasks.reduce(Int64(0)) { $0 + ($1.key & mask != 0 ? $1.value : 0) }
                }
                return row + [count.map(Cell.integer) ?? .empty]
            }))
        }
        return result
    }
}
