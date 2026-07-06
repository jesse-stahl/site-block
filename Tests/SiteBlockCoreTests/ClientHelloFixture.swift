import Foundation

/// Assembles a byte-accurate TLS ClientHello record containing an SNI `server_name` extension
/// for `host`, matching the layout `TLSClientHello.sni` parses. Building the bytes ourselves
/// (rather than capturing a real handshake) keeps the tests deterministic and self-checking:
/// we know exactly what should come out. Shared by the parser tests and the TLS sensor tests.
func makeClientHello(host: String, includeSNI: Bool = true) -> Data {
    var hostBytes = Array(host.utf8)
    if hostBytes.count > 0xFFFF {
        hostBytes = Array(hostBytes.prefix(0xFFFF))
    }

    // --- extensions ---
    var extensions = Data()
    if includeSNI {
        var serverNameEntry = Data()
        serverNameEntry.append(0x00) // name_type: host_name
        serverNameEntry.append(uint16: UInt16(hostBytes.count))
        serverNameEntry.append(contentsOf: hostBytes)

        var serverNameList = Data()
        serverNameList.append(uint16: UInt16(serverNameEntry.count))
        serverNameList.append(serverNameEntry)

        extensions.append(uint16: 0x0000) // extension type: server_name
        extensions.append(uint16: UInt16(serverNameList.count))
        extensions.append(serverNameList)
    } else {
        // Some other, irrelevant extension (e.g. a fake "renegotiation_info").
        extensions.append(uint16: 0xFF01)
        extensions.append(uint16: 1)
        extensions.append(contentsOf: [0x00])
    }

    // --- hello body ---
    var hello = Data()
    hello.append(contentsOf: [0x03, 0x03]) // client_version: TLS 1.2
    hello.append(contentsOf: [UInt8](repeating: 0xAB, count: 32)) // random

    let sessionID: [UInt8] = []
    hello.append(UInt8(sessionID.count))
    hello.append(contentsOf: sessionID)

    let cipherSuites: [UInt8] = [0xC0, 0x2F, 0xC0, 0x30] // arbitrary, 2 suites
    hello.append(uint16: UInt16(cipherSuites.count))
    hello.append(contentsOf: cipherSuites)

    let compressionMethods: [UInt8] = [0x00]
    hello.append(UInt8(compressionMethods.count))
    hello.append(contentsOf: compressionMethods)

    hello.append(uint16: UInt16(extensions.count))
    hello.append(extensions)

    // --- handshake header ---
    var handshake = Data()
    handshake.append(0x01) // ClientHello
    handshake.append(uint24: UInt32(hello.count))
    handshake.append(hello)

    // --- record header ---
    var record = Data()
    record.append(0x16) // handshake content type
    record.append(contentsOf: [0x03, 0x01]) // record version
    record.append(uint16: UInt16(handshake.count))
    record.append(handshake)

    return record
}

extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func append(uint24 value: UInt32) {
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
