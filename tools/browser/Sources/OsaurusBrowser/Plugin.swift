import AppKit
import Foundation
import WebKit

// MARK: - Headless Browser Manager

/// Manages a headless WKWebView instance for browser automation
private class HeadlessBrowser: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var navigationSemaphore = DispatchSemaphore(value: 0)
    private var navigationError: Error?
    private var isLoaded = false

    override init() {
        super.init()

        // Ensure we're on the main thread for WebKit operations
        if Thread.isMainThread {
            setupWebView()
        } else {
            DispatchQueue.main.sync {
                self.setupWebView()
            }
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Create a headless webview (no window needed)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.navigationDelegate = self

        // Enable JavaScript
        if #available(macOS 14.0, *) {
            webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
    }

    // MARK: - Navigation

    func navigate(to urlString: String, timeout: TimeInterval = 30) -> (success: Bool, error: String?) {
        guard let url = URL(string: urlString) else {
            return (false, "Invalid URL: \(urlString)")
        }

        navigationError = nil
        isLoaded = false
        navigationSemaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            let request = URLRequest(url: url, timeoutInterval: timeout)
            self.webView.load(request)
        }

        let result = navigationSemaphore.wait(timeout: .now() + timeout)

        if result == .timedOut {
            return (false, "Navigation timed out after \(timeout) seconds")
        }

        if let error = navigationError {
            return (false, error.localizedDescription)
        }

        return (true, nil)
    }

    // MARK: - JavaScript Execution

    func evaluateJavaScript(_ script: String, timeout: TimeInterval = 10) -> (result: Any?, error: String?) {
        var jsResult: Any?
        var jsError: String?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(script) { result, error in
                jsResult = result
                if let error = error {
                    jsError = error.localizedDescription
                }
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)

        if waitResult == .timedOut {
            return (nil, "JavaScript execution timed out")
        }

        return (jsResult, jsError)
    }

    // MARK: - Screenshot

    func takeScreenshot(fullPage: Bool = false) -> Data? {
        var imageData: Data?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            let config = WKSnapshotConfiguration()

            if fullPage {
                // Get full page dimensions
                self.webView.evaluateJavaScript(
                    "JSON.stringify({width: document.body.scrollWidth, height: document.body.scrollHeight})"
                ) { result, _ in
                    if let jsonString = result as? String,
                        let data = jsonString.data(using: .utf8),
                        let dimensions = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
                        let width = dimensions["width"],
                        let height = dimensions["height"]
                    {
                        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
                    }

                    self.captureSnapshot(config: config) { data in
                        imageData = data
                        semaphore.signal()
                    }
                }
            } else {
                self.captureSnapshot(config: config) { data in
                    imageData = data
                    semaphore.signal()
                }
            }
        }

        _ = semaphore.wait(timeout: .now() + 30)
        return imageData
    }

    private func captureSnapshot(config: WKSnapshotConfiguration, completion: @escaping (Data?) -> Void) {
        webView.takeSnapshot(with: config) { image, error in
            guard let image = image, error == nil else {
                completion(nil)
                return
            }

            // Convert NSImage to PNG data
            guard let tiffData = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiffData),
                let pngData = bitmap.representation(using: .png, properties: [:])
            else {
                completion(nil)
                return
            }

            completion(pngData)
        }
    }

    // MARK: - Properties

    var currentURL: String? {
        var url: String?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            url = self.webView.url?.absoluteString
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return url
    }

    var currentTitle: String? {
        var title: String?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            title = self.webView.title
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return title
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        navigationSemaphore.signal()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationError = error
        navigationSemaphore.signal()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationError = error
        navigationSemaphore.signal()
    }
}

// MARK: - JSON Helpers

private func escapeJSON(_ s: String) -> String {
    return
        s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

private func toJSONString(_ value: Any?) -> String {
    guard let value = value else { return "null" }

    if let string = value as? String {
        return "\"\(escapeJSON(string))\""
    } else if let number = value as? NSNumber {
        return "\(number)"
    } else if let bool = value as? Bool {
        return bool ? "true" : "false"
    } else if let array = value as? [Any] {
        let items = array.map { toJSONString($0) }.joined(separator: ",")
        return "[\(items)]"
    } else if let dict = value as? [String: Any] {
        let items = dict.map { "\"\(escapeJSON($0.key))\":\(toJSONString($0.value))" }.joined(separator: ",")
        return "{\(items)}"
    } else {
        return "\"\(escapeJSON(String(describing: value)))\""
    }
}

// MARK: - Plugin Context

private class PluginContext {
    lazy var browser: HeadlessBrowser = {
        // Ensure NSApplication is initialized for WebKit
        if NSApp == nil {
            DispatchQueue.main.sync {
                _ = NSApplication.shared
            }
        }
        return HeadlessBrowser()
    }()

    // MARK: - Tool Implementations

    func navigate(args: String) -> String {
        struct Args: Decodable {
            let url: String
            let wait_until: String?
            let timeout: Double?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: url\"}"
        }

        let result = browser.navigate(to: input.url, timeout: input.timeout ?? 30)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true, \"url\": \"\(escapeJSON(browser.currentURL ?? input.url))\"}"
    }

    func getContent(args: String) -> String {
        struct Args: Decodable {
            let selector: String?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(selector: nil)
        }

        let script: String
        if let selector = input.selector {
            script = "document.querySelector('\(selector)')?.innerText || ''"
        } else {
            script = "document.body.innerText"
        }

        let result = browser.evaluateJavaScript(script)

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        let content = result.result as? String ?? ""
        return "{\"content\": \"\(escapeJSON(content))\"}"
    }

    func getHTML(args: String) -> String {
        struct Args: Decodable {
            let selector: String?
            let outer: Bool?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(selector: nil, outer: nil)
        }

        let outer = input.outer ?? true
        let script: String

        if let selector = input.selector {
            let prop = outer ? "outerHTML" : "innerHTML"
            script = "document.querySelector('\(selector)')?.\(prop) || ''"
        } else {
            script = "document.documentElement.outerHTML"
        }

        let result = browser.evaluateJavaScript(script)

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        let html = result.result as? String ?? ""
        return "{\"html\": \"\(escapeJSON(html))\"}"
    }

    func executeScript(args: String) -> String {
        struct Args: Decodable {
            let script: String
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: script\"}"
        }

        let result = browser.evaluateJavaScript(input.script)

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        return "{\"result\": \(toJSONString(result.result))}"
    }

    func click(args: String) -> String {
        struct Args: Decodable {
            let selector: String
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: selector\"}"
        }

        let script = """
            (function() {
                const el = document.querySelector('\(input.selector)');
                if (!el) return {success: false, error: 'Element not found'};
                el.click();
                return {success: true};
            })()
            """

        let result = browser.evaluateJavaScript(script)

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        if let dict = result.result as? [String: Any],
            let success = dict["success"] as? Bool,
            !success,
            let error = dict["error"] as? String
        {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        return "{\"success\": true, \"selector\": \"\(escapeJSON(input.selector))\"}"
    }

    func type(args: String) -> String {
        struct Args: Decodable {
            let selector: String
            let text: String
            let clear: Bool?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: selector, text\"}"
        }

        let clear = input.clear ?? true
        let escapedText = input.text.replacingOccurrences(of: "'", with: "\\'")

        let script = """
            (function() {
                const el = document.querySelector('\(input.selector)');
                if (!el) return {success: false, error: 'Element not found'};
                if (\(clear)) el.value = '';
                el.value += '\(escapedText)';
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                return {success: true};
            })()
            """

        let result = browser.evaluateJavaScript(script)

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        if let dict = result.result as? [String: Any],
            let success = dict["success"] as? Bool,
            !success,
            let error = dict["error"] as? String
        {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        return "{\"success\": true, \"selector\": \"\(escapeJSON(input.selector))\"}"
    }

    func select(args: String) -> String {
        struct Args: Decodable {
            let selector: String
            let value: String
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: selector, value\"}"
        }

        let script = """
            (function() {
                const el = document.querySelector('\(input.selector)');
                if (!el) return {success: false, error: 'Element not found'};
                el.value = '\(input.value.replacingOccurrences(of: "'", with: "\\'"))';
                el.dispatchEvent(new Event('change', {bubbles: true}));
                return {success: true};
            })()
            """

        let result = browser.evaluateJavaScript(script)

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        return "{\"success\": true}"
    }

    func screenshot(args: String) -> String {
        struct Args: Decodable {
            let path: String?
            let full_page: Bool?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(path: nil, full_page: nil)
        }

        guard let imageData = browser.takeScreenshot(fullPage: input.full_page ?? false) else {
            return "{\"error\": \"Failed to capture screenshot\"}"
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let path: String
        if let customPath = input.path {
            path = (customPath as NSString).expandingTildeInPath
        } else {
            path =
                FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
                .appendingPathComponent("screenshot_\(timestamp).png")
                .path
        }

        do {
            try imageData.write(to: URL(fileURLWithPath: path))
            return "{\"success\": true, \"path\": \"\(escapeJSON(path))\", \"size\": \(imageData.count)}"
        } catch {
            return "{\"error\": \"Failed to save screenshot: \(escapeJSON(error.localizedDescription))\"}"
        }
    }

    func getURL(args: String) -> String {
        let url = browser.currentURL ?? ""
        return "{\"url\": \"\(escapeJSON(url))\"}"
    }

    func getTitle(args: String) -> String {
        let title = browser.currentTitle ?? ""
        return "{\"title\": \"\(escapeJSON(title))\"}"
    }

    func wait(args: String) -> String {
        struct Args: Decodable {
            let selector: String
            let timeout: Double?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: selector\"}"
        }

        let timeout = input.timeout ?? 10
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let script = "document.querySelector('\(input.selector)') !== null"
            let result = browser.evaluateJavaScript(script)

            if let found = result.result as? Bool, found {
                return "{\"success\": true, \"selector\": \"\(escapeJSON(input.selector))\"}"
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        return "{\"error\": \"Timeout waiting for element: \(escapeJSON(input.selector))\"}"
    }
}

// MARK: - C ABI

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer
private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
    @convention(c) (
        osr_plugin_ctx_t?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
}

private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
    guard let ptr = strdup(s) else { return nil }
    return UnsafePointer(ptr)
}

private var api: osr_plugin_api = {
    var api = osr_plugin_api()

    api.free_string = { ptr in
        if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
    }

    api.`init` = {
        let ctx = PluginContext()
        return Unmanaged.passRetained(ctx).toOpaque()
    }

    api.destroy = { ctxPtr in
        guard let ctxPtr = ctxPtr else { return }
        Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
    }

    api.get_manifest = { _ in
        let manifest = """
            {
              "plugin_id": "osaurus.browser",
              "version": "1.0.0",
              "description": "Headless browser automation using WebKit WebView",
              "capabilities": {
                "tools": [
                  {"id": "browser_navigate", "description": "Navigate to a URL", "parameters": {"type":"object","properties":{"url":{"type":"string"},"timeout":{"type":"number"}},"required":["url"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "browser_get_content", "description": "Get text content of the page", "parameters": {"type":"object","properties":{"selector":{"type":"string"}},"required":[]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "browser_get_html", "description": "Get HTML of the page", "parameters": {"type":"object","properties":{"selector":{"type":"string"},"outer":{"type":"boolean"}},"required":[]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "browser_execute_script", "description": "Execute JavaScript", "parameters": {"type":"object","properties":{"script":{"type":"string"}},"required":["script"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "browser_click", "description": "Click an element", "parameters": {"type":"object","properties":{"selector":{"type":"string"}},"required":["selector"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "browser_type", "description": "Type text into an input", "parameters": {"type":"object","properties":{"selector":{"type":"string"},"text":{"type":"string"},"clear":{"type":"boolean"}},"required":["selector","text"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "browser_select", "description": "Select dropdown option", "parameters": {"type":"object","properties":{"selector":{"type":"string"},"value":{"type":"string"}},"required":["selector","value"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "browser_screenshot", "description": "Take a screenshot", "parameters": {"type":"object","properties":{"path":{"type":"string"},"full_page":{"type":"boolean"}},"required":[]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "browser_get_url", "description": "Get current URL", "parameters": {"type":"object","properties":{},"required":[]}, "requirements": [], "permission_policy": "allow"},
                  {"id": "browser_get_title", "description": "Get page title", "parameters": {"type":"object","properties":{},"required":[]}, "requirements": [], "permission_policy": "allow"},
                  {"id": "browser_wait", "description": "Wait for element", "parameters": {"type":"object","properties":{"selector":{"type":"string"},"timeout":{"type":"number"}},"required":["selector"]}, "requirements": [], "permission_policy": "ask"}
                ]
              }
            }
            """
        return makeCString(manifest)
    }

    api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
        guard let ctxPtr = ctxPtr,
            let typePtr = typePtr,
            let idPtr = idPtr,
            let payloadPtr = payloadPtr
        else { return nil }

        let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let type = String(cString: typePtr)
        let id = String(cString: idPtr)
        let payload = String(cString: payloadPtr)

        guard type == "tool" else {
            return makeCString("{\"error\": \"Unknown capability type\"}")
        }

        switch id {
        case "browser_navigate":
            return makeCString(ctx.navigate(args: payload))
        case "browser_get_content":
            return makeCString(ctx.getContent(args: payload))
        case "browser_get_html":
            return makeCString(ctx.getHTML(args: payload))
        case "browser_execute_script":
            return makeCString(ctx.executeScript(args: payload))
        case "browser_click":
            return makeCString(ctx.click(args: payload))
        case "browser_type":
            return makeCString(ctx.type(args: payload))
        case "browser_select":
            return makeCString(ctx.select(args: payload))
        case "browser_screenshot":
            return makeCString(ctx.screenshot(args: payload))
        case "browser_get_url":
            return makeCString(ctx.getURL(args: payload))
        case "browser_get_title":
            return makeCString(ctx.getTitle(args: payload))
        case "browser_wait":
            return makeCString(ctx.wait(args: payload))
        default:
            return makeCString("{\"error\": \"Unknown tool: \(id)\"}")
        }
    }

    return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
    return UnsafeRawPointer(&api)
}
