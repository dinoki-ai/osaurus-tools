import Foundation

// MARK: - HTTP Helper

private func performRequest(
    url: String,
    method: String = "GET",
    headers: [String: String]? = nil,
    body: String? = nil,
    timeout: TimeInterval = 30
) -> (data: Data?, response: HTTPURLResponse?, error: String?) {

    guard let requestURL = URL(string: url) else {
        return (nil, nil, "Invalid URL: \(url)")
    }

    var request = URLRequest(url: requestURL)
    request.httpMethod = method.uppercased()
    request.timeoutInterval = timeout

    // Set headers
    headers?.forEach { key, value in
        request.setValue(value, forHTTPHeaderField: key)
    }

    // Set body
    if let body = body {
        request.httpBody = body.data(using: .utf8)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultResponse: HTTPURLResponse?
    var resultError: String?

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            resultError = error.localizedDescription
        } else {
            resultData = data
            resultResponse = response as? HTTPURLResponse
        }
        semaphore.signal()
    }

    task.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 5)

    return (resultData, resultResponse, resultError)
}

private func escapeJSON(_ s: String) -> String {
    return
        s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

private func stripHTML(_ html: String) -> String {
    // Basic HTML tag stripping
    var text = html

    // Remove script and style contents
    let patterns = [
        "<script[^>]*>[\\s\\S]*?</script>",
        "<style[^>]*>[\\s\\S]*?</style>",
        "<[^>]+>",
        "&nbsp;",
        "&amp;",
        "&lt;",
        "&gt;",
        "&quot;",
    ]
    let replacements = ["", "", "", " ", "&", "<", ">", "\""]

    for (i, pattern) in patterns.enumerated() {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: replacements[i]
            )
        }
    }

    // Normalize whitespace
    if let regex = try? NSRegularExpression(pattern: "\\s+", options: []) {
        text = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Tool Implementations

private struct FetchTool {
    let name = "fetch"

    func run(args: String) -> String {
        struct Args: Decodable {
            let url: String
            let method: String?
            let headers: [String: String]?
            let body: String?
            let timeout: Double?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: url\"}"
        }

        let result = performRequest(
            url: input.url,
            method: input.method ?? "GET",
            headers: input.headers,
            body: input.body,
            timeout: input.timeout ?? 30
        )

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        guard let response = result.response else {
            return "{\"error\": \"No response received\"}"
        }

        let bodyString = result.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        // Build headers JSON
        var headersJSON = "{"
        var first = true
        for (key, value) in response.allHeaderFields {
            if !first { headersJSON += "," }
            first = false
            headersJSON += "\"\(escapeJSON(String(describing: key)))\":\"\(escapeJSON(String(describing: value)))\""
        }
        headersJSON += "}"

        return """
            {"status": \(response.statusCode), "headers": \(headersJSON), "body": "\(escapeJSON(bodyString))"}
            """
    }
}

private struct FetchJSONTool {
    let name = "fetch_json"

    func run(args: String) -> String {
        struct Args: Decodable {
            let url: String
            let method: String?
            let headers: [String: String]?
            let body: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: url\"}"
        }

        var headers = input.headers ?? [:]
        headers["Accept"] = "application/json"
        if input.body != nil && headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }

        let result = performRequest(
            url: input.url,
            method: input.method ?? "GET",
            headers: headers,
            body: input.body
        )

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        guard let response = result.response else {
            return "{\"error\": \"No response received\"}"
        }

        guard let responseData = result.data else {
            return "{\"status\": \(response.statusCode), \"data\": null}"
        }

        // Try to parse as JSON
        if let json = try? JSONSerialization.jsonObject(with: responseData),
            let jsonData = try? JSONSerialization.data(withJSONObject: json),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            return "{\"status\": \(response.statusCode), \"data\": \(jsonString)}"
        }

        // Return as string if not valid JSON
        let bodyString = String(data: responseData, encoding: .utf8) ?? ""
        return "{\"status\": \(response.statusCode), \"data\": \"\(escapeJSON(bodyString))\"}"
    }
}

private struct FetchHTMLTool {
    let name = "fetch_html"

    func run(args: String) -> String {
        struct Args: Decodable {
            let url: String
            let selector: String?
            let text_only: Bool?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: url\"}"
        }

        let result = performRequest(
            url: input.url,
            method: "GET",
            headers: ["Accept": "text/html"]
        )

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        guard let response = result.response else {
            return "{\"error\": \"No response received\"}"
        }

        guard let responseData = result.data,
            var html = String(data: responseData, encoding: .utf8)
        else {
            return "{\"status\": \(response.statusCode), \"content\": \"\"}"
        }

        // Basic selector extraction (simplified - looks for id or class)
        if let selector = input.selector {
            // Try to find content by id or class (very basic implementation)
            if selector.hasPrefix("#") {
                let id = String(selector.dropFirst())
                if let regex = try? NSRegularExpression(
                    pattern: "id=[\"']\(id)[\"'][^>]*>([\\s\\S]*?)</",
                    options: .caseInsensitive
                ) {
                    if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                        let range = Range(match.range(at: 1), in: html)
                    {
                        html = String(html[range])
                    }
                }
            } else if selector.hasPrefix(".") {
                let className = String(selector.dropFirst())
                if let regex = try? NSRegularExpression(
                    pattern: "class=[\"'][^\"']*\(className)[^\"']*[\"'][^>]*>([\\s\\S]*?)</",
                    options: .caseInsensitive
                ) {
                    if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                        let range = Range(match.range(at: 1), in: html)
                    {
                        html = String(html[range])
                    }
                }
            }
        }

        // Strip HTML if requested
        if input.text_only == true {
            html = stripHTML(html)
        }

        return "{\"status\": \(response.statusCode), \"content\": \"\(escapeJSON(html))\"}"
    }
}

private struct DownloadTool {
    let name = "download"

    func run(args: String) -> String {
        struct Args: Decodable {
            let url: String
            let filename: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: url\"}"
        }

        let result = performRequest(url: input.url, method: "GET")

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        guard let responseData = result.data else {
            return "{\"error\": \"No data received\"}"
        }

        // Determine filename
        var filename = input.filename
        if filename == nil {
            // Try to get from URL
            if let url = URL(string: input.url) {
                filename = url.lastPathComponent
            }
            if filename == nil || filename!.isEmpty || filename == "/" {
                let timestamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                filename = "download_\(timestamp)"
            }
        }

        let downloadsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent(filename!)

        do {
            try responseData.write(to: downloadsPath)
            return
                "{\"success\": true, \"path\": \"\(escapeJSON(downloadsPath.path))\", \"size\": \(responseData.count)}"
        } catch {
            return "{\"error\": \"Failed to save file: \(escapeJSON(error.localizedDescription))\"}"
        }
    }
}

// MARK: - Plugin Context

private class PluginContext {
    let fetchTool = FetchTool()
    let fetchJSONTool = FetchJSONTool()
    let fetchHTMLTool = FetchHTMLTool()
    let downloadTool = DownloadTool()
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
              "plugin_id": "osaurus.fetch",
              "version": "1.0.0",
              "description": "HTTP client for fetching web content and making API requests",
              "capabilities": {
                "tools": [
                  {"id": "fetch", "description": "Fetch content from a URL with full HTTP control", "parameters": {"type":"object","properties":{"url":{"type":"string"},"method":{"type":"string"},"headers":{"type":"object"},"body":{"type":"string"},"timeout":{"type":"number"}},"required":["url"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "fetch_json", "description": "Fetch and parse JSON from a URL", "parameters": {"type":"object","properties":{"url":{"type":"string"},"method":{"type":"string"},"headers":{"type":"object"},"body":{"type":"string"}},"required":["url"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "fetch_html", "description": "Fetch HTML content, optionally extracting text", "parameters": {"type":"object","properties":{"url":{"type":"string"},"selector":{"type":"string"},"text_only":{"type":"boolean"}},"required":["url"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "download", "description": "Download a file to Downloads folder", "parameters": {"type":"object","properties":{"url":{"type":"string"},"filename":{"type":"string"}},"required":["url"]}, "requirements": [], "permission_policy": "ask"}
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
        case ctx.fetchTool.name:
            return makeCString(ctx.fetchTool.run(args: payload))
        case ctx.fetchJSONTool.name:
            return makeCString(ctx.fetchJSONTool.run(args: payload))
        case ctx.fetchHTMLTool.name:
            return makeCString(ctx.fetchHTMLTool.run(args: payload))
        case ctx.downloadTool.name:
            return makeCString(ctx.downloadTool.run(args: payload))
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
