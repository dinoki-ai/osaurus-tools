import XCTest

@testable import OsaurusBrowser

final class ActionSnapshotTests: BrowserTestCase {

    override func setUp() {
        super.setUp()
        guard context != nil else { return }
        navigateToFixture("login-form", detail: "standard")
    }

    func testClick_returnsSnapshot() throws {
        try skipIfNeeded()
        let snapshot = takeSnapshot()
        XCTAssertTrue(snapshot.contains("[E"), "Should have element refs")

        let result = browserSync {
            self.context!.click(args: "{\"selector\": \"#forgot-link\", \"detail\": \"standard\"}")
        }

        XCTAssertTrue(result.contains("Action: click succeeded"))
        XCTAssertTrue(result.contains("[E"), "Click should return updated snapshot")
    }

    func testClick_compactDetail() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.click(args: "{\"selector\": \"#forgot-link\", \"detail\": \"compact\"}")
        }

        XCTAssertTrue(result.contains("Action: click succeeded"))
        XCTAssertTrue(result.contains("- page:"), "Should have page header")
        XCTAssertTrue(result.contains("[E"), "Should have element refs")
    }

    func testClick_noneDetail() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.click(args: "{\"selector\": \"#forgot-link\", \"detail\": \"none\"}")
        }

        XCTAssertEqual(result, "Action: click succeeded")
        XCTAssertFalse(result.contains("[E"), "None detail should not include snapshot")
    }

    func testClick_domStabilityWait() throws {
        try skipIfNeeded()
        browserSync {
            _ = self.context!.type(
                args:
                    "{\"selector\": \"#email\", \"text\": \"test@example.com\", \"detail\": \"none\"}"
            )
            _ = self.context!.type(
                args:
                    "{\"selector\": \"#password\", \"text\": \"password123\", \"detail\": \"none\"}"
            )
        }

        let result = browserSync {
            self.context!.click(args: "{\"selector\": \"#login-btn\", \"detail\": \"standard\"}")
        }

        XCTAssertTrue(result.contains("Action: click succeeded"))
        XCTAssertTrue(
            result.contains("Dashboard") || result.contains("Log out"),
            "Snapshot after click should reflect DOM changes")
    }

    func testClick_fullDetail() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.click(args: "{\"selector\": \"#forgot-link\", \"detail\": \"full\"}")
        }

        XCTAssertTrue(result.contains("Action: click succeeded"))
        XCTAssertTrue(result.contains("- text:"), "Full detail should include page text")
        XCTAssertTrue(result.contains("id=\""), "Full detail should include element IDs")
    }

    func testType_returnsSnapshot() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.type(
                args:
                    "{\"selector\": \"#email\", \"text\": \"hello@test.com\", \"detail\": \"standard\"}"
            )
        }

        XCTAssertTrue(result.contains("Action: type succeeded"))
        XCTAssertTrue(result.contains("[E"), "Type should return updated snapshot")
    }

    func testSelect_returnsSnapshot() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.select(
                args:
                    "{\"selector\": \"#role\", \"values\": [\"admin\"], \"detail\": \"standard\"}")
        }

        XCTAssertTrue(result.contains("Action: select succeeded"))
        XCTAssertTrue(result.contains("[E"), "Select should return updated snapshot")
    }

    func testScroll_returnsSnapshot() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.scroll(
                args: "{\"direction\": \"down\", \"detail\": \"standard\"}")
        }

        XCTAssertTrue(result.contains("Action: scroll succeeded"))
        XCTAssertTrue(result.contains("[E"), "Scroll should return updated snapshot")
    }

    func testHover_returnsSnapshot() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.hover(
                args: "{\"selector\": \"#login-btn\", \"detail\": \"standard\"}")
        }

        XCTAssertTrue(result.contains("Action: hover succeeded"))
        XCTAssertTrue(result.contains("[E"), "Hover should return updated snapshot")
    }
}
