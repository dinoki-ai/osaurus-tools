import XCTest

@testable import OsaurusBrowser

final class EndToEndTests: BrowserTestCase {

    func testLoginFlow_twoToolCalls() throws {
        try skipIfNeeded()

        let navResult = navigateToFixture("login-form", detail: "standard")
        XCTAssertTrue(navResult.contains("Action: navigate to"))
        XCTAssertTrue(navResult.contains("[E"), "Navigate should return snapshot with refs")
        XCTAssertTrue(navResult.contains("input"), "Should see input elements")

        let batchResult = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "user@example.com"},
                            {"action": "type", "selector": "#password", "text": "secretpass"},
                            {"action": "click", "selector": "#login-btn"}
                        ],
                        "detail": "standard"
                    }
                    """)
        }

        XCTAssertTrue(batchResult.contains("Action: browser_do completed (3 actions)"))
        XCTAssertTrue(
            batchResult.contains("Dashboard") || batchResult.contains("Log out"),
            "After login, dashboard should be visible in snapshot")
    }

    func testLoginFlow_fullDetail() throws {
        try skipIfNeeded()

        let navResult = navigateToFixture("login-form", detail: "full")

        XCTAssertTrue(navResult.contains("- text:"), "Full detail should have page text")
        XCTAssertTrue(navResult.contains("id=\""), "Full detail should have element IDs")
        XCTAssertTrue(
            navResult.contains("aria-label=\"Email address\""),
            "Full detail should include aria-labels")

        let batchResult = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "admin@example.com"},
                            {"action": "type", "selector": "#password", "text": "admin123"},
                            {"action": "click", "selector": "#login-btn"}
                        ],
                        "detail": "full"
                    }
                    """)
        }

        XCTAssertTrue(batchResult.contains("Action: browser_do completed"))
        XCTAssertTrue(batchResult.contains("- text:"), "Full detail result should have page text")
    }

    func testLoginFlow_compactDetail() throws {
        try skipIfNeeded()

        let navResult = navigateToFixture("login-form", detail: "compact")

        XCTAssertTrue(navResult.contains("- page: Login | url:"))
        XCTAssertTrue(navResult.contains("[E"))

        let batchResult = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "test@test.com"},
                            {"action": "type", "selector": "#password", "text": "pass"},
                            {"action": "click", "selector": "#login-btn"}
                        ],
                        "detail": "compact"
                    }
                    """)
        }

        XCTAssertTrue(batchResult.contains("Action: browser_do completed"))
        XCTAssertTrue(batchResult.contains("| url:"), "Compact should use pipe separator")
    }

    func testInteractiveElements_allTypes() throws {
        try skipIfNeeded()
        let result = navigateToFixture("interactive-elements", detail: "standard")

        XCTAssertTrue(result.contains("input"), "Should have input elements")
        XCTAssertTrue(result.contains("button"), "Should have button elements")
        XCTAssertTrue(result.contains("link"), "Should have link elements")
        XCTAssertTrue(
            result.contains("checkbox") || result.contains("radio"),
            "Should have checkbox or radio elements")
        XCTAssertTrue(result.contains("select"), "Should have select elements")
    }

    func testInteractiveElements_hiddenNotIncluded() throws {
        try skipIfNeeded()
        let result = navigateToFixture("interactive-elements", detail: "standard")

        XCTAssertFalse(result.contains("Hidden Display"), "display:none elements should be excluded")
        XCTAssertFalse(
            result.contains("Hidden Visibility"), "visibility:hidden elements should be excluded")
        XCTAssertFalse(result.contains("Hidden Opacity"), "opacity:0 elements should be excluded")
    }

    func testSelectDropdown_andVerify() throws {
        try skipIfNeeded()
        navigateToFixture("login-form", detail: "none")

        let result = browserSync {
            self.context!.select(
                args:
                    "{\"selector\": \"#role\", \"values\": [\"admin\"], \"detail\": \"standard\"}")
        }

        XCTAssertTrue(result.contains("Action: select succeeded"))
        XCTAssertTrue(result.contains("[E"), "Should return updated snapshot after select")
    }

    func testCheckbox_andVerify() throws {
        try skipIfNeeded()
        navigateToFixture("login-form", detail: "none")

        let result = browserSync {
            self.context!.click(
                args: "{\"selector\": \"#remember\", \"detail\": \"standard\"}")
        }

        XCTAssertTrue(result.contains("Action: click succeeded"))
        XCTAssertTrue(result.contains("checkbox") || result.contains("[E"))
    }
}
