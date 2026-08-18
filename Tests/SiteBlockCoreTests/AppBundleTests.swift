import XCTest
@testable import SiteBlockCore

final class AppBundleTests: XCTestCase {

    func testBundleRootIsOutermostContentsParent() {
        XCTAssertEqual(
            AppBundle.bundleRoot(forExecutable: "/Applications/Discord.app/Contents/MacOS/Discord"),
            "/Applications/Discord.app")
        XCTAssertEqual(
            AppBundle.bundleRoot(forExecutable:
                "/Applications/Discord.app/Contents/Frameworks/Discord Helper (GPU).app/Contents/MacOS/Discord Helper (GPU)"),
            "/Applications/Discord.app",
            "nested helper apps resolve to the OUTER app")
        XCTAssertEqual(
            AppBundle.bundleRoot(forExecutable:
                "/Users/j/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"),
            "/Users/j/Library/Application Support/Steam/Steam.AppBundle/Steam",
            "Steam's client bundle has no .app suffix")
    }

    func testBundleRootIsNilForBareExecutables() {
        XCTAssertNil(AppBundle.bundleRoot(forExecutable: "/usr/bin/ssh"))
        XCTAssertNil(AppBundle.bundleRoot(forExecutable: ""))
        XCTAssertNil(AppBundle.bundleRoot(forExecutable: "/Contents/MacOS/x"),
                     "a root of empty string is not a bundle")
    }

    func testBundleIdentifierReadsInfoPlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-\(UUID().uuidString)/Fake.app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.Fake", "CFBundleName": "Fake"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        XCTAssertEqual(AppBundle.bundleIdentifier(atRoot: root.path), "com.example.Fake")
    }

    func testBundleIdentifierIsNilWhenNoPlist() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-\(UUID().uuidString)/Nope.app").path
        XCTAssertNil(AppBundle.bundleIdentifier(atRoot: root))
    }
}
