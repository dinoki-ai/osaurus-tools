import XCTest

@testable import OsaurusBrowser

final class NavigateTests: BrowserTestCase {

    func testNavigate_returnsSnapshot() throws {
        try skipIfNeeded()
        let result = navigateToFixture("login-form")

        XCTAssertTrue(result.contains("Action: navigate to"))
        XCTAssertTrue(result.contains("succeeded"))
        XCTAssertTrue(result.contains("[E"), "Should contain element refs")
    }

    func testNavigate_compactDetail() throws {
        try skipIfNeeded()
        let result = navigateToFixture("login-form", detail: "compact")

        XCTAssertTrue(result.contains("- page: Login | url:"))

        let lines = result.split(separator: "\n")
        let elementLine = lines.first { $0.contains("[E1]") }
        XCTAssertNotNil(elementLine)

        if let line = elementLine {
            XCTAssertTrue(
                line.contains("[E2]") || line.contains("[E3]"),
                "Compact should put multiple elements on one line")
        }
    }

    func testNavigate_standardDetail() throws {
        try skipIfNeeded()
        let result = navigateToFixture("login-form", detail: "standard")

        XCTAssertTrue(result.contains("- page: Login\n"))
        XCTAssertTrue(result.contains("- url:"))

        let elementLines = result.split(separator: "\n").filter { $0.hasPrefix("[E") }
        XCTAssertGreaterThan(elementLines.count, 1, "Standard should have elements on separate lines")
    }

    func testNavigate_fullDetail() throws {
        try skipIfNeeded()
        let result = navigateToFixture("login-form", detail: "full")

        XCTAssertTrue(result.contains("- text:"), "Full detail should include page text excerpt")
        XCTAssertTrue(result.contains("id=\""), "Full detail should include element IDs")
    }

    func testNavigate_noneDetail() throws {
        try skipIfNeeded()
        let result = navigateToFixture("login-form", detail: "none")

        XCTAssertTrue(result.contains("Action: navigate to"))
        XCTAssertTrue(result.contains("succeeded"))
        XCTAssertFalse(result.contains("[E"), "None detail should not contain element refs")
        XCTAssertFalse(result.contains("- page:"), "None detail should not contain page header")
    }

    func testNavigate_invalidURL() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.navigate(args: "{\"url\": \"not-a-url\"}")
        }
        XCTAssertTrue(result.contains("error"), "Should return error for invalid URL")
    }
}
