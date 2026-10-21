import XCTest
@testable import SiteBlockCore

final class HelperInfoTests: XCTestCase {

    func testClientRequirementPinsTheAppAndTeam() {
        XCTAssertEqual(
            HelperInfo.clientRequirement(teamID: "AB12CD34EF"),
            "anchor apple generic and identifier \"today.siteblock.SiteBlock\" "
                + "and certificate leaf[subject.OU] = \"AB12CD34EF\"")
    }

    func testClientRequirementRejectsMalformedTeamIDs() {
        // Fail closed: a bad id must never widen the requirement (or inject into it).
        XCTAssertNil(HelperInfo.clientRequirement(teamID: ""))
        XCTAssertNil(HelperInfo.clientRequirement(teamID: "ab12cd34ef"))
        XCTAssertNil(HelperInfo.clientRequirement(teamID: "AB12CD34E"))
        XCTAssertNil(HelperInfo.clientRequirement(teamID: "AB12\" or 1"))
    }

    func testRequirementCompilesWithTheSecurityFramework() throws {
        let text = try XCTUnwrap(HelperInfo.clientRequirement(teamID: "AB12CD34EF"))
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
    }
}
