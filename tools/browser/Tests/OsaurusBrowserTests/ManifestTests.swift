import XCTest

@testable import OsaurusBrowser

final class ManifestTests: XCTestCase {

    private var manifest: [String: Any]!

    override func setUp() {
        super.setUp()

        let json = PluginContext.getManifestJSON()
        guard let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Failed to parse manifest JSON")
            return
        }
        manifest = parsed
    }

    private func getTools() -> [[String: Any]] {
        guard let capabilities = manifest["capabilities"] as? [String: Any],
            let tools = capabilities["tools"] as? [[String: Any]]
        else {
            return []
        }
        return tools
    }

    private func getTool(id: String) -> [String: Any]? {
        return getTools().first { ($0["id"] as? String) == id }
    }

    // MARK: - Tests

    func testManifestIsValidJSON() {
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest["plugin_id"] as? String, "osaurus.browser")
        XCTAssertEqual(manifest["name"] as? String, "Browser")
    }

    func testManifestContainsBrowserDo() {
        let tool = getTool(id: "browser_do")
        XCTAssertNotNil(tool, "browser_do tool should exist in manifest")
    }

    func testBrowserDoHasActionsParam() {
        guard let tool = getTool(id: "browser_do"),
            let params = tool["parameters"] as? [String: Any],
            let props = params["properties"] as? [String: Any],
            let required = params["required"] as? [String]
        else {
            XCTFail("browser_do tool or its parameters not found")
            return
        }

        XCTAssertNotNil(props["actions"], "browser_do should have 'actions' property")
        XCTAssertTrue(required.contains("actions"), "browser_do should require 'actions'")
    }

    func testBrowserDoHasDetailParam() {
        guard let tool = getTool(id: "browser_do"),
            let params = tool["parameters"] as? [String: Any],
            let props = params["properties"] as? [String: Any]
        else {
            XCTFail("browser_do parameters not found")
            return
        }
        XCTAssertNotNil(props["detail"], "browser_do should have 'detail' property")
    }

    func testActionToolsHaveDetailParam() {
        let toolsWithDetail = [
            "browser_navigate", "browser_snapshot", "browser_click",
            "browser_type", "browser_select", "browser_hover", "browser_scroll",
        ]

        for toolId in toolsWithDetail {
            guard let tool = getTool(id: toolId),
                let params = tool["parameters"] as? [String: Any],
                let props = params["properties"] as? [String: Any]
            else {
                XCTFail("Tool \(toolId) or its parameters not found")
                continue
            }

            XCTAssertNotNil(
                props["detail"],
                "Tool \(toolId) should have 'detail' property"
            )
        }
    }

    func testAllToolsExist() {
        let expectedTools = [
            "browser_navigate", "browser_snapshot", "browser_click",
            "browser_type", "browser_select", "browser_hover", "browser_scroll",
            "browser_do", "browser_press_key", "browser_wait_for",
            "browser_screenshot", "browser_execute_script",
        ]

        let toolIds = getTools().compactMap { $0["id"] as? String }

        for expected in expectedTools {
            XCTAssertTrue(toolIds.contains(expected), "Missing tool: \(expected)")
        }
    }
}
