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
