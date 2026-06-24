import Foundation

/// Minimal parser for Safari's Cookies.binarycookies format.
/// Layout: magic "cook", BE page count, BE page sizes, then pages.
/// Each page: 0x00000100, LE cookie count, LE cookie offsets, then cookie records.
enum BinaryCookies {
    struct Cookie { var domain: String; var name: String; var value: String }

    static func parse(_ data: Data) -> [Cookie] {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0...3] == [0x63, 0x6f, 0x6f, 0x6b] else { return [] }  // "cook"

        // All integer reads are bounds-checked: the file is untrusted (it can be
        // truncated, corrupt, or a future Safari format), and an out-of-range
        // Array subscript is a hard trap that cannot be caught — it would crash
        // the whole app during cookie import.
        func beU32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return Int(bytes[o]) << 24 | Int(bytes[o+1]) << 16 | Int(bytes[o+2]) << 8 | Int(bytes[o+3])
        }
        func leU32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return Int(bytes[o]) | Int(bytes[o+1]) << 8 | Int(bytes[o+2]) << 16 | Int(bytes[o+3]) << 24
        }
        func cString(_ start: Int) -> String {
            guard start >= 0, start < bytes.count else { return "" }
            var end = start
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        guard let pageCount = beU32(4), pageCount >= 0 else { return [] }
        var offset = 8
        var pageSizes: [Int] = []
        for _ in 0..<pageCount {
            guard let size = beU32(offset), size > 0 else { return [] }
            pageSizes.append(size); offset += 4
        }

        var cookies: [Cookie] = []
        var pageStart = offset
        for size in pageSizes {
            guard size >= 8, pageStart + size <= bytes.count else { break }
            let p = pageStart
            let pageEnd = pageStart + size
            // The cookie-offset table (count entries of 4 bytes) must fit inside the
            // page; a corrupt count must never drive the loop past the page bounds.
            guard let rawCount = leU32(p + 4), rawCount > 0,
                  p + 8 + rawCount * 4 <= pageEnd else { pageStart += size; continue }
            for i in 0..<rawCount {
                guard let cookieOffset = leU32(p + 8 + i * 4) else { continue }
                let c = p + cookieOffset
                // Each cookie record's fixed header must lie within this page.
                guard c >= p, c + 56 <= pageEnd,
                      let domainOff = leU32(c + 16),
                      let nameOff = leU32(c + 20),
                      let valueOff = leU32(c + 28) else { continue }
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
