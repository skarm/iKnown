import Foundation
import SQLite3

enum ArchivedFeature {
    enum Value {
        case boolean(Bool)
        case category
    }

    static func read(_ row: OpaquePointer, _ column: Int32) -> Value? {
        if sqlite3_column_type(row,column) == SQLITE_INTEGER {
            return .boolean(sqlite3_column_int64(row,column) != 0)
        }
        let count = Int(sqlite3_column_bytes(row,column))
        guard (40...1_048_576).contains(count), let blob = sqlite3_column_blob(row,column)
        else { return nil }
        let bytes = UnsafeRawBufferPointer(start:blob,count:count)
        return BinaryPlist(bytes)?.feature()
    }

    // A restricted reader for Apple's binary keyed-archive layout. It only
    // follows object references and reads scalars; archive classes are never loaded.
    private struct BinaryPlist {
        let bytes: UnsafeRawBufferPointer
        let offsets: Int
        let offsetWidth: Int
        let referenceWidth: Int
        let objects: Int
        let root: Int

        init?(_ bytes: UnsafeRawBufferPointer) {
            guard bytes.count >= 40, bytes.prefix(8).elementsEqual("bplist00".utf8) else { return nil }
            let trailer = bytes.count-32
            let offsetWidth = Int(bytes[trailer+6])
            let referenceWidth = Int(bytes[trailer+7])
            guard (1...8).contains(offsetWidth), (1...8).contains(referenceWidth),
                  let objects = Self.read(bytes,trailer+8,8), objects > 0,
                  let root = Self.read(bytes,trailer+16,8), root < objects,
                  let offsets = Self.read(bytes,trailer+24,8), offsets >= 8, offsets <= trailer,
                  objects <= (trailer-offsets)/offsetWidth else { return nil }
            self.bytes = bytes
            self.offsets = offsets
            self.offsetWidth = offsetWidth
            self.referenceWidth = referenceWidth
            self.objects = objects
            self.root = root
        }

        func feature() -> Value? {
            guard let objectList = lookup("$objects",in:root), let array = container(objectList,kind:0xa),
                  array.count > 1, let wrapper = reference(array.start+referenceWidth),
                  let value = lookup("value",in:wrapper), let position = position(value) else { return nil }
            let marker = bytes[position]
            if marker >> 4 == 0x8 {
                let width = Int(marker & 15)+1
                guard let uid = Self.read(bytes,position+1,width), uid > 0, uid < array.count,
                      let item = reference(array.start+uid*referenceWidth) else { return nil }
                return scalar(item)
            }
            return scalar(value)
        }

        private func scalar(_ object: Int) -> Value? {
            guard let position = position(object) else { return nil }
            let marker = bytes[position]
            let kind = marker >> 4
            let info = Int(marker & 15)
            switch kind {
            case 0:
                if marker == 0x08 { return .boolean(false) }
                if marker == 0x09 { return .boolean(true) }
                return nil
            case 1 where info <= 3:
                let size = 1 << info
                guard position + 1 + size <= offsets else { return nil }
                return .boolean(bytes[(position+1)..<(position+1+size)].contains { $0 != 0 })
            case 2 where info == 2 || info == 3:
                guard let value = bits(position+1,1<<info) else { return nil }
                let real = info == 2 ? Double(Float(bitPattern:UInt32(value))) : Double(bitPattern:value)
                return real.isFinite ? .boolean(real != 0) : nil
            case 5,6,7:
                return .category
            default:
                return nil
            }
        }

        private func lookup(_ key: String, in object: Int) -> Int? {
            guard let dictionary = container(object,kind:0xd) else { return nil }
            for i in 0..<dictionary.count {
                guard let keyRef = reference(dictionary.start+i*referenceWidth),
                      let keyPosition = position(keyRef) else { return nil }
                if bytes[keyPosition]>>4 == 5, let value = payload(keyPosition),
                   value.start + value.count <= offsets,
                   bytes[value.start..<(value.start+value.count)].elementsEqual(key.utf8) {
                    return reference(dictionary.start+(dictionary.count+i)*referenceWidth)
                }
            }
            return nil
        }

        private func container(_ object: Int, kind: UInt8) -> (count:Int,start:Int)? {
            guard let position = position(object), bytes[position]>>4 == kind,
                  let result = payload(position), result.start <= offsets else { return nil }
            let width = referenceWidth * (kind == 0xd ? 2 : 1)
            guard result.count <= (offsets-result.start)/width else { return nil }
            return result
        }

        private func payload(_ position: Int) -> (count:Int,start:Int)? {
            let count = Int(bytes[position]&15)
            if count < 15 { return (count,position+1) }
            guard position+1 < offsets, bytes[position+1]>>4 == 1 else { return nil }
            let exponent = Int(bytes[position+1]&15)
            guard exponent <= 3 else { return nil }
            let width = 1 << exponent
            guard position+2+width <= offsets,
                  let length = Self.read(bytes,position+2,width), length <= offsets else { return nil }
            return (length,position+2+width)
        }

        private func reference(_ position: Int) -> Int? {
            guard position+referenceWidth <= offsets,
                  let value = Self.read(bytes,position,referenceWidth), value < objects else { return nil }
            return value
        }

        private func position(_ object: Int) -> Int? {
            guard (0..<objects).contains(object),
                  let offset = Self.read(bytes,offsets+object*offsetWidth,offsetWidth),
                  (8..<offsets).contains(offset) else { return nil }
            return offset
        }

        private func bits(_ position: Int, _ width: Int) -> UInt64? {
            guard position+width <= offsets else { return nil }
            return bytes[position..<(position+width)].reduce(0) { ($0<<8)|UInt64($1) }
        }

        private static func read(_ bytes:UnsafeRawBufferPointer,_ position:Int,_ width:Int) -> Int? {
            guard (1...8).contains(width), position >= 0, position <= bytes.count-width else { return nil }
            let value = bytes[position..<(position+width)].reduce(UInt64(0)) { ($0<<8)|UInt64($1) }
            return Int(exactly:value)
        }
    }
}
