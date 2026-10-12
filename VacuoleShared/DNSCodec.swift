// Copyright 2026 Wang Jian
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// DNS message codec: supports A/AAAA records in queries and responses only.
/// Enough for the "transparent relay + resolve A/AAAA into routes" need.
public enum DNSCodec {

    // MARK: - DNS header (12 bytes)
    //                                1  1  1  1  1  1
    //  0  1  2  3  4  5  6  7  8  9  0  1  2  3  4  5
    // +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
    // |                      ID                         |
    // +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
    // |QR|Opcode |AA|TC|RD|RA| Z|AD|CD|   RCODE        |
    // +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
    // |                    QDCOUNT                       |
    // |                    ANCOUNT                       |
    // |                    NSCOUNT                       |
    // |                    ARCOUNT                       |
    // +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+

    public struct DNSHeader {
        public var id: UInt16
        public var flags: UInt16
        public var qdCount: UInt16
        public var anCount: UInt16
        public var nsCount: UInt16
        public var arCount: UInt16

        public init(id: UInt16, flags: UInt16, qdCount: UInt16 = 0,
                    anCount: UInt16 = 0, nsCount: UInt16 = 0, arCount: UInt16 = 0) {
            self.id = id
            self.flags = flags
            self.qdCount = qdCount
            self.anCount = anCount
            self.nsCount = nsCount
            self.arCount = arCount
        }

        var isResponse: Bool { (flags & 0x8000) != 0 }
        var rcode: UInt16 { flags & 0x000F }

        func data() -> Data {
            var d = Data()
            d.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0) })
            d.append(contentsOf: withUnsafeBytes(of: flags.bigEndian) { Array($0) })
            d.append(contentsOf: withUnsafeBytes(of: qdCount.bigEndian) { Array($0) })
            d.append(contentsOf: withUnsafeBytes(of: anCount.bigEndian) { Array($0) })
            d.append(contentsOf: withUnsafeBytes(of: nsCount.bigEndian) { Array($0) })
            d.append(contentsOf: withUnsafeBytes(of: arCount.bigEndian) { Array($0) })
            return d
        }
    }

    // MARK: - DNS question section

    public struct DNSQuestion {
        public var name: String    // e.g. "example.com."
        public var qtype: UInt16   // A=1, AAAA=28
        public var qclass: UInt16  // IN=1

        public init(name: String, qtype: UInt16, qclass: UInt16 = 1) {
            self.name = name
            self.qtype = qtype
            self.qclass = qclass
        }
    }

    // MARK: - DNS resource record

    public struct DNSRecord {
        public var name: String
        public var type: UInt16   // A=1, AAAA=28
        public var rclass: UInt16
        public var ttl: UInt32
        public var rdata: Data    // 4 bytes for A, 16 for AAAA

        public var ipAddress: String? {
            if type == 1 && rdata.count == 4 {
                return rdata.map { String($0) }.joined(separator: ".")
            }
            if type == 28 && rdata.count == 16 {
                let b = [UInt8](rdata)
                var hextets: [String] = []
                for i in stride(from: 0, to: 16, by: 2) {
                    hextets.append(String(format: "%x", (UInt16(b[i]) << 8) | UInt16(b[i + 1])))
                }
                return hextets.joined(separator: ":")
            }
            return nil
        }
    }

    public static let TYPE_A: UInt16 = 1
    public static let TYPE_AAAA: UInt16 = 28
    public static let CLASS_IN: UInt16 = 1

    // MARK: - Decoding

    /// Parse the query name and A/AAAA records from a DNS response.
    public static func parseResponse(_ data: Data) -> (name: String?, records: [DNSRecord]) {
        guard data.count >= 12 else { return (nil, []) }
        let header = parseHeader(data)
        guard header.isResponse else { return (nil, []) }

        var offset = 12
        var name: String?

        // Parse the question section
        if header.qdCount > 0 {
            let (n, newOffset) = parseName(data, offset: offset)
            name = n
            offset = newOffset
            // Skip qtype(2) + qclass(2)
            offset += 4
        }

        // Parse the answer section
        var records: [DNSRecord] = []
        for _ in 0..<header.anCount {
            guard offset < data.count else { break }
            let (rname, newOffset) = parseName(data, offset: offset)
            offset = newOffset
            guard offset + 10 <= data.count else { break }
            let rtype = readU16(data, offset)
            let rclass = readU16(data, offset + 2)
            let ttl = readU32(data, offset + 4)
            let rdLength = Int(readU16(data, offset + 8))
            offset += 10
            guard offset + rdLength <= data.count else { break }
            let rdata = data.subdata(in: offset..<offset + rdLength)
            offset += rdLength
            // Keep A/AAAA only
            if rtype == TYPE_A || rtype == TYPE_AAAA {
                records.append(DNSRecord(name: rname, type: rtype, rclass: rclass, ttl: ttl, rdata: rdata))
            }
        }

        return (name, records)
    }

    /// Parse the query name from a DNS query message.
    public static func parseQuery(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let header = parseHeader(data)
        guard header.qdCount > 0 else { return nil }
        let (name, _) = parseName(data, offset: 12)
        return name
    }

    /// Extract the transaction ID from a query message.
    public static func parseQueryID(_ data: Data) -> UInt16? {
        guard data.count >= 2 else { return nil }
        return readU16(data, 0)
    }

    // MARK: - Internals

    private static func parseHeader(_ data: Data) -> DNSHeader {
        DNSHeader(
            id: readU16(data, 0),
            flags: readU16(data, 2),
            qdCount: readU16(data, 4),
            anCount: readU16(data, 6),
            nsCount: readU16(data, 8),
            arCount: readU16(data, 10)
        )
    }

    /// Parse a DNS name (supports compression pointers).
    private static func parseName(_ data: Data, offset: Int) -> (String, Int) {
        var parts: [String] = []
        var pos = offset
        var jumped = false
        var jumpPos = offset

        while pos < data.count {
            let len = Int(data[pos])
            if len == 0 {
                pos += 1
                break
            }
            if (len & 0xC0) == 0xC0 {
                // Compression pointer
                if pos + 1 >= data.count { break }
                let ptr = ((len & 0x3F) << 8) | Int(data[pos + 1])
                if !jumped { jumpPos = pos + 2 }
                pos = ptr
                jumped = true
                continue
            }
            if pos + 1 + len > data.count { break }
            let label = data.subdata(in: pos + 1..<pos + 1 + len)
            parts.append(String(data: label, encoding: .utf8) ?? "")
            pos += 1 + len
        }
        let name = parts.isEmpty ? "" : parts.joined(separator: ".") + "."
        let finalOffset = jumped ? jumpPos : pos
        return (name, finalOffset)
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
               (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
}