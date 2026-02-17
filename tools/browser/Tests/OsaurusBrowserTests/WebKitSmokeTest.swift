import AppKit
import WebKit
import XCTest

@testable import OsaurusBrowser

final class WebKitSmokeTest: BrowserTestCase {

    func testCanCreateHeadlessBrowser() throws {
        try skipIfNeeded()
        XCTAssertNotNil(context, "PluginContext should be created")
    }

    func testCanNavigateToBlank() throws {
        try skipIfNeeded()
        let result = browserSync {
            self.context!.navigate(args: "{\"url\": \"about:blank\", \"detail\": \"none\"}")
        }
        XCTAssertTrue(result.contains("Action: navigate to"))
    }
}
