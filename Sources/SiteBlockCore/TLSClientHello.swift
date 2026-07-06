import Foundation

/// Minimal TLS ClientHello inspection: extracts the SNI server_name so the privileged helper can
/// tell WHICH blocked domain a browser tried to reach on port 443 without completing a handshake.
public enum TLSClientHello {

    /// The SNI host in `data` (the first bytes read from a fresh TLS connection), or nil if the
    /// bytes are not a complete-enough ClientHello or carry no SNI extension. Never throws, never
    /// crashes on malformed/truncated/hostile input.
    public static func sni(in data: Data) -> String? {
        var reader = Reader(data)

        // TLS record header: content type (0x16 = handshake), version (2 bytes, ignored),
        // record length (2 bytes). We only support the ClientHello fitting in a single record;
        // a hello split across records is rare in practice and not worth the complexity here.
        guard let contentType = reader.readByte(), contentType == 0x16 else { return nil }
        guard reader.skip(2) else { return nil }
        guard let recordLength = reader.readUInt16() else { return nil }
        guard reader.remaining >= Int(recordLength) else { return nil }
        // Constrain all further parsing to the record body: bytes beyond it (e.g. a second TLS
        // record coalesced into the same TCP read) must never satisfy inner length fields.
        var recordReader = Reader(reader.slice(Int(recordLength)))

        // Handshake header: msg type (0x01 = ClientHello), 3-byte length.
        guard let handshakeType = recordReader.readByte(), handshakeType == 0x01 else { return nil }
        guard let helloLength = recordReader.readUInt24() else { return nil }
        guard recordReader.remaining >= helloLength else { return nil }

        // client_version(2) + random(32).
        guard recordReader.skip(2 + 32) else { return nil }

        // session_id: 1-byte length prefix.
        guard let sessionIDLength = recordReader.readByte() else { return nil }
        guard recordReader.skip(Int(sessionIDLength)) else { return nil }

        // cipher_suites: 2-byte length prefix (in bytes).
        guard let cipherSuitesLength = recordReader.readUInt16() else { return nil }
        guard recordReader.skip(Int(cipherSuitesLength)) else { return nil }

        // compression_methods: 1-byte length prefix.
        guard let compressionMethodsLength = recordReader.readByte() else { return nil }
        guard recordReader.skip(Int(compressionMethodsLength)) else { return nil }

        // extensions: 2-byte total length, then a sequence of (type:2, length:2, body).
        guard let extensionsLength = recordReader.readUInt16() else { return nil }
        guard recordReader.remaining >= Int(extensionsLength) else { return nil }
        var extensionsReader = Reader(recordReader.slice(Int(extensionsLength)))

        while extensionsReader.remaining > 0 {
            guard let extType = extensionsReader.readUInt16() else { return nil }
            guard let extLength = extensionsReader.readUInt16() else { return nil }
            guard let extBody = extensionsReader.takeSlice(Int(extLength)) else { return nil }

            if extType == 0x0000 {
                return parseServerName(extBody)
            }
        }
        return nil
    }

    /// Parse the `server_name` extension body: ServerNameList { uint16 length, entries }
    /// where each entry is `type(1) + name_length(2) + name`. We only recognize type 0
    /// (host_name), per RFC 6066.
    private static func parseServerName(_ body: Data) -> String? {
        var reader = Reader(body)
        guard let listLength = reader.readUInt16() else { return nil }
        guard reader.remaining >= Int(listLength) else { return nil }
        // Constrain iteration to the declared list length — trailing bytes beyond it in a
        // malformed extension body must not be read as entries.
        var listReader = Reader(reader.slice(Int(listLength)))

        while listReader.remaining > 0 {
            guard let nameType = listReader.readByte() else { return nil }
            guard let nameLength = listReader.readUInt16() else { return nil }
            guard let nameBytes = listReader.takeSlice(Int(nameLength)) else { return nil }

            guard nameType == 0x00 else { continue }
            guard let name = String(data: nameBytes, encoding: .ascii) else { return nil }
            guard !name.isEmpty else { return nil }
            return name.lowercased()
        }
        return nil
    }

    /// A tiny bounds-checked cursor over `Data`. Every read fails (returns nil / false) rather
    /// than trapping when there are not enough bytes left, so hostile or truncated input can
    /// never crash the parser.
    private struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        var remaining: Int { data.endIndex - offset }

        mutating func readByte() -> UInt8? {
            guard offset < data.endIndex else { return nil }
            let byte = data[offset]
            offset += 1
            return byte
        }

        mutating func readUInt16() -> Int? {
            guard remaining >= 2 else { return nil }
            let high = Int(data[offset])
            let low = Int(data[offset + 1])
            offset += 2
            return (high << 8) | low
        }

        mutating func readUInt24() -> Int? {
            guard remaining >= 3 else { return nil }
            let b0 = Int(data[offset])
            let b1 = Int(data[offset + 1])
            let b2 = Int(data[offset + 2])
            offset += 3
            return (b0 << 16) | (b1 << 8) | b2
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, remaining >= count else { return false }
            offset += count
            return true
        }

        /// Consume and return the next `count` bytes as a fresh `Data`, or nil if not enough
        /// bytes remain.
        mutating func takeSlice(_ count: Int) -> Data? {
            guard count >= 0, remaining >= count else { return nil }
            let slice = data[offset..<(offset + count)]
            offset += count
            return Data(slice)
        }

        /// Consume and return the rest of `count` bytes without validating type — used where
        /// the caller has already bounds-checked and wants an independent sub-reader.
        mutating func slice(_ count: Int) -> Data {
            let end = min(offset + max(count, 0), data.endIndex)
            let result = Data(data[offset..<end])
            offset = end
            return result
        }
    }
}
