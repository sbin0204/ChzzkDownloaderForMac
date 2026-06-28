import CommonCrypto
import Foundation

/// AES-128 CBC for HLS `#EXT-X-KEY:METHOD=AES-128` segments. CryptoKit has no CBC,
/// so this uses CommonCrypto. The parallel segment downloader cannot otherwise
/// handle encrypted streams (which is why such streams currently go through ffmpeg).
public enum AES128 {
    /// Decrypts one PKCS7-padded AES-128-CBC segment. Returns nil on bad sizes or
    /// a decrypt failure.
    public static func decryptCBC(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128, !data.isEmpty else { return nil }
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, data.count,
                            outBuf.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
    }

    /// HLS default IV when `#EXT-X-KEY` omits one: the segment's media sequence as
    /// a 16-byte big-endian value.
    public static func iv(forSequence sequence: Int) -> Data {
        var be = UInt64(UInt(bitPattern: sequence)).bigEndian
        let low = withUnsafeBytes(of: &be) { Data($0) }   // 8 bytes
        return Data(repeating: 0, count: 8) + low          // 16 bytes, sequence in the low word
    }

    /// Parses an `IV=0x…` hex string (with or without `0x`) into 16 bytes.
    public static func iv(fromHex hex: String) -> Data? {
        var s = hex.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count == 32 else { return nil }   // 16 bytes
        var bytes = Data(capacity: 16)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
