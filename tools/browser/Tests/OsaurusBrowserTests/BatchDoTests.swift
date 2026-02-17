import XCTest

@testable import OsaurusBrowser

final class BatchDoTests: BrowserTestCase {

    override func setUp() {
        super.setUp()
        guard context != nil else { return }
        navigateToFixture("login-form", detail: "none")
        _ = takeSnapshot()
    }

    func testBatchDo_multipleActions() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "user@test.com"},
                            {"action": "type", "selector": "#password", "text": "pass123"},
                            {"action": "click", "selector": "#login-btn"}
                        ],
                        "detail": "standard"
                    }
                    """)
        }

        XCTAssertTrue(result.contains("Action: browser_do completed (3 actions)"))
        XCTAssertTrue(result.contains("[E"), "Should return final snapshot")
    }

    func testBatchDo_refsRemainValidDuringBatch() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "test@test.com"},
                            {"action": "type", "selector": "#password", "text": "secret"},
                            {"action": "click", "selector": "#remember"}
                        ],
                        "detail": "compact"
                    }
                    """)
        }

        XCTAssertTrue(result.contains("Action: browser_do completed (3 actions)"))
        XCTAssertFalse(result.contains("Error:"), "Batch should complete without errors")
    }

    func testBatchDo_failFastOnError() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "hello"},
                            {"action": "click", "ref": "E999"},
                            {"action": "type", "selector": "#password", "text": "should not run"}
                        ],
                        "detail": "standard"
                    }
                    """)
        }

        XCTAssertTrue(result.contains("Error: Action 1"), "Should identify which action failed")
        XCTAssertTrue(result.contains("click"), "Should identify the action type that failed")
    }

    func testBatchDo_failFastIncludesSnapshot() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "click", "ref": "INVALID_REF"}
                        ],
                        "detail": "standard"
                    }
                    """)
        }

        XCTAssertTrue(result.contains("Error:"), "Should contain error")
        XCTAssertTrue(
            result.contains("- page:") || result.contains("[E"),
            "Error response should include a snapshot for recovery")
    }

    func testBatchDo_emptyActions() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [],
                        "detail": "standard"
                    }
                    """)
        }

        XCTAssertTrue(result.contains("Action: browser_do completed (0 actions)"))
    }

    func testBatchDo_detailParameter() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "test@test.com"}
                        ],
                        "detail": "full"
                    }
                    """)
        }

        XCTAssertTrue(result.contains("Action: browser_do completed"))
        XCTAssertTrue(
            result.contains("- text:") || result.contains("id=\""),
            "Full detail should include extra context")
    }

    func testBatchDo_compactDetail() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "test@test.com"}
                        ],
                        "detail": "compact"
                    }
                    """)
        }

        XCTAssertTrue(result.contains("Action: browser_do completed"))
        XCTAssertTrue(result.contains("- page:"))
        XCTAssertTrue(result.contains("|"), "Compact header should use pipe separator")
    }

    func testBatchDo_noneDetail() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "test@test.com"}
                        ],
                        "detail": "none"
                    }
                    """)
        }

        XCTAssertEqual(result, "Action: browser_do completed (1 actions)")
        XCTAssertFalse(result.contains("[E"), "None should not include snapshot")
    }

    func testBatchDo_unknownAction() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "fly", "ref": "E1"}
                        ],
                        "detail": "standard"
                    }
                    """)
        }

        XCTAssertTrue(result.contains("Error: Action 0 has unknown action type 'fly'"))
    }

    func testBatchDo_missingRequiredParam() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email"}
                        ],
                        "detail": "standard"
                    }
                    """)
        }

        XCTAssertTrue(
            result.contains("Error: Action 0 (type) missing required 'text' parameter"))
    }

    func testBatchDo_waitAfterDomstable() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.batchDo(
                args: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "hello"}
                        ],
                        "wait_after": "domstable",
                        "detail": "compact"
                    }
                    """)
        }

        XCTAssertTrue(result.contains("Action: browser_do completed"))
        XCTAssertFalse(result.contains("Error:"))
    }
}
