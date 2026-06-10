import Foundation

/// Minimal parser for Safari's Cookies.binarycookies format.
/// Layout: magic "cook", BE page count, BE page sizes, then pages.
/// Each page: 0x00000100, LE cookie count, LE cookie offsets, then cookie records.
enum BinaryCookies {
    struct Cookie { var domain: String; var name: String; var value: String }

    static func parse(_ data: Data) -> [Cookie] {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0...3] == [0x63, 0x6f, 0x6f, 0x6b] else { return [] }  // "cook"

        func beU32(_ o: Int) -> Int {
            Int(bytes[o]) << 24 | Int(bytes[o+1]) << 16 | Int(bytes[o+2]) << 8 | Int(bytes[o+3])
        }
        func leU32(_ o: Int) -> Int {
            Int(bytes[o]) | Int(bytes[o+1]) << 8 | Int(bytes[o+2]) << 16 | Int(bytes[o+3]) << 24
        }
        func cString(_ start: Int) -> String {
            guard start >= 0, start < bytes.count else { return "" }
            var end = start
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        let pageCount = beU32(4)
        var offset = 8
        var pageSizes: [Int] = []
        for _ in 0..<pageCount {
            guard offset + 4 <= bytes.count else { return [] }
            pageSizes.append(beU32(offset)); offset += 4
        }

        var cookies: [Cookie] = []
        var pageStart = offset
        for size in pageSizes {
            guard pageStart + size <= bytes.count else { break }
            let p = pageStart
            let count = leU32(p + 4)
            for i in 0..<count {
                let cookieOffset = leU32(p + 8 + i * 4)
                let c = p + cookieOffset
                guard c + 56 <= bytes.count else { continue }
                let domainOff = leU32(c + 16)
                let nameOff = leU32(c + 20)
                let valueOff = leU32(c + 28)
                let domain = cString(c + domainOff)
                let name = cString(c + nameOff)
                let value = cString(c + valueOff)
                if !name.isEmpty { cookies.append(Cookie(domain: domain, name: name, value: value)) }
            }
            pageStart += size
        }
        return cookies
    }
}
