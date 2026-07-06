import XCTest
@testable import SiteBlockCore

final class TLSClientHelloTests: XCTestCase {

    // MARK: - Basic parsing

    func testValidHelloWithSNIParsesFacebook() {
        let data = makeClientHello(host: "facebook.com")
        XCTAssertEqual(TLSClientHello.sni(in: data), "facebook.com")
    }

    func testValidHelloWithDifferentHost() {
        let data = makeClientHello(host: "www.example.org")
        XCTAssertEqual(TLSClientHello.sni(in: data), "www.example.org")
    }

    func testHelloWithoutSNIExtensionReturnsNil() {
        let data = makeClientHello(host: "facebook.com", includeSNI: false)
        XCTAssertNil(TLSClientHello.sni(in: data))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(TLSClientHello.sni(in: Data()))
    }

    func testTruncatedAtVariousPrefixesNeverCrashes() {
        let data = makeClientHello(host: "facebook.com")
        var offset = 0
        while offset < data.count {
            let prefix = data.prefix(offset)
            let result = TLSClientHello.sni(in: prefix)
            if let result {
                XCTAssertEqual(result, "facebook.com", "any non-nil result at offset \(offset) must be the correct host")
            }
            offset += 10
        }
    }

    func testNonTLSGarbageReturnsNil() {
        let garbage = Data("GET / HTTP/1.1\r\nHost: facebook.com\r\n\r\n".utf8)
        XCTAssertNil(TLSClientHello.sni(in: garbage))
    }

    func testUppercaseHostIsLowercased() {
        let data = makeClientHello(host: "FaceBook.COM")
        XCTAssertEqual(TLSClientHello.sni(in: data), "facebook.com")
    }

    // MARK: - Fuzzing

    /// Deterministic LCG so the fuzz run is reproducible across CI runs, unlike
    /// SystemRandomNumberGenerator.
    private struct LCG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testCoalescedSecondRecordDoesNotLeakIntoParse() {
        // Two TLS records coalesced into one TCP read: parsing must be confined to the first
        // record's declared length. A truncated first record must fail even though the second
        // record's bytes could numerically satisfy the inner length fields.
        let full = makeClientHello(host: "facebook.com")
        let second = makeClientHello(host: "attacker.example")

        // Intact first record followed by a second record: first record parses normally.
        XCTAssertEqual(TLSClientHello.sni(in: full + second), "facebook.com")

        // First record's declared length trimmed to cut into the hello body (record header says
        // fewer bytes than the handshake needs): must return nil, never read into record two.
        var truncated = [UInt8](full)
        let declaredLength = (Int(truncated[3]) << 8) | Int(truncated[4]) // record length field
        let cut = declaredLength - 10
        truncated[3] = UInt8((cut >> 8) & 0xFF)
        truncated[4] = UInt8(cut & 0xFF)
        let coalesced = Data(truncated.prefix(5 + cut)) + second
        XCTAssertNil(TLSClientHello.sni(in: coalesced))
    }

    func testServerNameListLengthBoundsIteration() {
        // A ServerNameList that declares length zero but is followed by a well-formed entry:
        // bytes beyond the declared list length must not be parsed as entries.
        var body = Data()
        body.append(uint16: 0) // declared ServerNameList length: ZERO
        body.append(0x00)      // ...but a host_name entry follows anyway
        body.append(uint16: 12)
        body.append(contentsOf: Array("facebook.com".utf8))
        let hello = makeClientHelloWithRawSNIBody(body)
        XCTAssertNil(TLSClientHello.sni(in: hello), "entry beyond declared list length must be ignored")
    }

    /// Build a hello whose server_name extension body is exactly `rawBody` (possibly malformed).
    private func makeClientHelloWithRawSNIBody(_ rawBody: Data) -> Data {
        var extensions = Data()
        extensions.append(uint16: 0x0000)
        extensions.append(uint16: UInt16(rawBody.count))
        extensions.append(rawBody)

        var hello = Data()
        hello.append(contentsOf: [0x03, 0x03])
        hello.append(contentsOf: [UInt8](repeating: 0xAB, count: 32))
        hello.append(0x00) // empty session_id
        hello.append(uint16: 2)
        hello.append(contentsOf: [0xC0, 0x2F]) // one cipher suite
        hello.append(0x01)
        hello.append(0x00) // null compression
        hello.append(uint16: UInt16(extensions.count))
        hello.append(extensions)

        var handshake = Data()
        handshake.append(0x01)
        handshake.append(uint24: UInt32(hello.count))
        handshake.append(hello)

        var record = Data()
        record.append(0x16)
        record.append(contentsOf: [0x03, 0x01])
        record.append(uint16: UInt16(handshake.count))
        record.append(handshake)
        return record
    }

    func testFuzzMutatedHellosNeverCrash() {
        let base = makeClientHello(host: "facebook.com")
        var rng = LCG(seed: 0xC0FFEE)

        for _ in 0..<200 {
            var mutated = [UInt8](base)
            guard !mutated.isEmpty else { continue }

            let mutationCount = Int.random(in: 1...5, using: &rng)
            for _ in 0..<mutationCount {
                let index = Int.random(in: 0..<mutated.count, using: &rng)
                mutated[index] = UInt8.random(in: 0...255, using: &rng)
            }

            // Occasionally also truncate, to combine both kinds of corruption.
            let shouldTruncate = Bool.random(using: &rng)
            var finalBytes = mutated
            if shouldTruncate {
                let cut = Int.random(in: 0...mutated.count, using: &rng)
                finalBytes = Array(mutated.prefix(cut))
            }

            // The only assertion is "does not crash"; the result content is unconstrained
            // for hostile/mutated input.
            _ = TLSClientHello.sni(in: Data(finalBytes))
        }
    }
}
