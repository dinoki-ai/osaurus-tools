import Foundation

// MARK: - HTTP Helper

private func performRequest(
    url: String,
    headers: [String: String]? = nil,
    timeout: TimeInterval = 30
) -> (data: Data?, response: HTTPURLResponse?, error: String?) {

    guard let requestURL = URL(string: url) else {
        return (nil, nil, "Invalid URL: \(url)")
    }

    var request = URLRequest(url: requestURL)
    request.httpMethod = "GET"
    request.timeoutInterval = timeout

    // Set default headers to mimic a browser
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

    headers?.forEach { key, value in
        request.setValue(value, forHTTPHeaderField: key)
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

private func urlEncode(_ s: String) -> String {
    return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
}

private func decodeHTMLEntities(_ s: String) -> String {
    var result = s
    let entities = [
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&apos;": "'",
        "&#39;": "'",
        "&nbsp;": " ",
        "&#x27;": "'",
        "&#x2F;": "/",
        "&mdash;": "—",
        "&ndash;": "–",
        "&hellip;": "…",
    ]
    for (entity, char) in entities {
        result = result.replacingOccurrences(of: entity, with: char)
    }
    // Handle numeric entities
    if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
    }
    return result
}

private func stripHTML(_ html: String) -> String {
    var text = html
    // Remove tags
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        text = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
    return decodeHTMLEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - DuckDuckGo Search Parser

private struct SearchResult {
    let title: String
    let url: String
    let snippet: String
}

private struct NewsResult {
    let title: String
    let url: String
    let snippet: String
    let source: String
    let date: String
}

private struct ImageResult {
    let title: String
    let url: String
    let imageUrl: String
    let thumbnailUrl: String
    let width: Int
    let height: Int
}

/// Parse DuckDuckGo HTML search results
private func parseDDGResults(html: String, maxResults: Int) -> [SearchResult] {
    var results: [SearchResult] = []

    // DuckDuckGo Lite HTML pattern: results are in <a class="result-link"> tags
    // For regular DDG: results are in result__* classes

    // Pattern for DDG lite version
    let resultPattern = "<a[^>]*class=\"result-link\"[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
    _ = "<td[^>]*class=\"result-snippet\"[^>]*>([^<]+(?:<[^>]+>[^<]*)*)</td>"  // snippet pattern for future use

    // Try lite pattern first
    if let linkRegex = try? NSRegularExpression(pattern: resultPattern, options: .caseInsensitive) {
        let range = NSRange(html.startIndex..., in: html)
        let matches = linkRegex.matches(in: html, range: range)

        for match in matches.prefix(maxResults) {
            if let urlRange = Range(match.range(at: 1), in: html),
                let titleRange = Range(match.range(at: 2), in: html)
            {
                let url = decodeHTMLEntities(String(html[urlRange]))
                let title = stripHTML(String(html[titleRange]))
                results.append(SearchResult(title: title, url: url, snippet: ""))
            }
        }
    }

    // If lite pattern didn't work, try regular DDG HTML pattern
    if results.isEmpty {
        // Pattern for regular DDG results: <a class="result__a" href="...">title</a>
        let regularPattern = "<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
        let regularSnippetPattern = "<a[^>]*class=\"[^\"]*result__snippet[^\"]*\"[^>]*>([^<]+(?:<[^>]+>[^<]*)*)</a>"

        if let linkRegex = try? NSRegularExpression(pattern: regularPattern, options: .caseInsensitive),
            let snippetRegex = try? NSRegularExpression(pattern: regularSnippetPattern, options: .caseInsensitive)
        {

            let range = NSRange(html.startIndex..., in: html)
            let linkMatches = linkRegex.matches(in: html, range: range)
            let snippetMatches = snippetRegex.matches(in: html, range: range)

            for (i, match) in linkMatches.prefix(maxResults).enumerated() {
                if let urlRange = Range(match.range(at: 1), in: html),
                    let titleRange = Range(match.range(at: 2), in: html)
                {
                    var url = decodeHTMLEntities(String(html[urlRange]))
                    let title = stripHTML(String(html[titleRange]))

                    // DDG wraps URLs, extract the actual URL
                    if url.contains("uddg="), let extracted = extractDDGUrl(url) {
                        url = extracted
                    }

                    var snippet = ""
                    if i < snippetMatches.count {
                        if let snippetRange = Range(snippetMatches[i].range(at: 1), in: html) {
                            snippet = stripHTML(String(html[snippetRange]))
                        }
                    }

                    results.append(SearchResult(title: title, url: url, snippet: snippet))
                }
            }
        }
    }

    // Fallback: Generic link extraction with context
    if results.isEmpty {
        let genericPattern = "<a[^>]*href=\"(https?://[^\"]+)\"[^>]*>([^<]+)</a>"
        if let regex = try? NSRegularExpression(pattern: genericPattern, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, range: range)

            for match in matches.prefix(maxResults * 2) {  // Get more, filter later
                if let urlRange = Range(match.range(at: 1), in: html),
                    let titleRange = Range(match.range(at: 2), in: html)
                {
                    var url = String(html[urlRange])
                    let title = stripHTML(String(html[titleRange]))

                    // Skip DDG internal links
                    if url.contains("duckduckgo.com") && !url.contains("uddg=") {
                        continue
                    }

                    // Extract wrapped URLs
                    if url.contains("uddg="), let extracted = extractDDGUrl(url) {
                        url = extracted
                    }

                    // Skip empty or very short titles
                    if title.count < 3 { continue }

                    results.append(SearchResult(title: title, url: url, snippet: ""))

                    if results.count >= maxResults { break }
                }
            }
        }
    }

    return results
}

private func extractDDGUrl(_ wrappedUrl: String) -> String? {
    // DDG wraps URLs like: //duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&...
    if let range = wrappedUrl.range(of: "uddg=") {
        var encoded = String(wrappedUrl[range.upperBound...])
        if let ampRange = encoded.range(of: "&") {
            encoded = String(encoded[..<ampRange.lowerBound])
        }
        return encoded.removingPercentEncoding
    }
    return nil
}

// MARK: - DuckDuckGo VQD Token Helper

/// Get VQD token required for DuckDuckGo image search API
private func getVQDToken(query: String) -> String? {
    let searchUrl = "https://duckduckgo.com/?q=\(urlEncode(query))"
    let result = performRequest(url: searchUrl)

    guard let data = result.data,
        let html = String(data: data, encoding: .utf8)
    else {
        return nil
    }

    // Look for vqd token in various patterns DDG uses
    let patterns = [
        "vqd=['\"]([^'\"]+)['\"]",
        "vqd=([\\d-]+)",
        "vqd%3D([^&\"']+)",
    ]

    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range),
                let tokenRange = Range(match.range(at: 1), in: html)
            {
                let token = String(html[tokenRange])
                if !token.isEmpty {
                    return token
                }
            }
        }
    }

    return nil
}

// MARK: - Tool Implementations

private struct SearchTool {
    let name = "search"

    func run(args: String) -> String {
        struct Args: Decodable {
            let query: String
            let max_results: Int?
            let region: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: query\"}"
        }

        let maxResults = input.max_results ?? 10
        let region = input.region ?? "wt-wt"

        // Use DuckDuckGo HTML version (more reliable parsing)
        let searchUrl = "https://html.duckduckgo.com/html/?q=\(urlEncode(input.query))&kl=\(region)"

        let result = performRequest(url: searchUrl)

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        guard let responseData = result.data,
            let html = String(data: responseData, encoding: .utf8)
        else {
            return "{\"error\": \"Failed to get search results\"}"
        }

        let results = parseDDGResults(html: html, maxResults: maxResults)

        if results.isEmpty {
            return "{\"results\": [], \"query\": \"\(escapeJSON(input.query))\", \"message\": \"No results found\"}"
        }

        let resultsJSON = results.map { r in
            "{\"title\": \"\(escapeJSON(r.title))\", \"url\": \"\(escapeJSON(r.url))\", \"snippet\": \"\(escapeJSON(r.snippet))\"}"
        }.joined(separator: ",")

        return "{\"results\": [\(resultsJSON)], \"query\": \"\(escapeJSON(input.query))\", \"count\": \(results.count)}"
    }
}

private struct SearchNewsTool {
    let name = "search_news"

    func run(args: String) -> String {
        struct Args: Decodable {
            let query: String
            let max_results: Int?
            let timelimit: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: query\"}"
        }

        let maxResults = input.max_results ?? 10

        // DuckDuckGo news search
        var searchUrl = "https://html.duckduckgo.com/html/?q=\(urlEncode(input.query))&iar=news"
        if let timelimit = input.timelimit {
            searchUrl += "&df=\(timelimit)"
        }

        let result = performRequest(url: searchUrl)

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        guard let responseData = result.data,
            let html = String(data: responseData, encoding: .utf8)
        else {
            return "{\"error\": \"Failed to get news results\"}"
        }

        let results = parseDDGResults(html: html, maxResults: maxResults)

        let resultsJSON = results.map { r in
            "{\"title\": \"\(escapeJSON(r.title))\", \"url\": \"\(escapeJSON(r.url))\", \"snippet\": \"\(escapeJSON(r.snippet))\"}"
        }.joined(separator: ",")

        return
            "{\"results\": [\(resultsJSON)], \"query\": \"\(escapeJSON(input.query))\", \"type\": \"news\", \"count\": \(results.count)}"
    }
}

private struct SearchImagesTool {
    let name = "search_images"

    func run(args: String) -> String {
        struct Args: Decodable {
            let query: String
            let max_results: Int?
            let size: String?
            let type: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: query\"}"
        }

        let maxResults = input.max_results ?? 10

        // Step 1: Get VQD token required for image search API
        guard let vqd = getVQDToken(query: input.query) else {
            return "{\"error\": \"Failed to get search token from DuckDuckGo\"}"
        }

        // Step 2: Build the images API URL
        var apiUrl = "https://duckduckgo.com/i.js?l=wt-wt&o=json&q=\(urlEncode(input.query))&vqd=\(vqd)&p=1"

        // Add size filter
        if let size = input.size {
            let sizeMap = ["small": "Small", "medium": "Medium", "large": "Large", "wallpaper": "Wallpaper"]
            if let mapped = sizeMap[size.lowercased()] {
                apiUrl += "&iaf=size:\(mapped)"
            }
        }

        // Add type filter
        if let type = input.type {
            let typeMap = ["photo": "photo", "clipart": "clipart", "gif": "gif", "transparent": "transparent"]
            if let mapped = typeMap[type.lowercased()] {
                apiUrl += "&iaf=type:\(mapped)"
            }
        }

        // Step 3: Request the images API
        let result = performRequest(url: apiUrl)

        if let error = result.error {
            return "{\"error\": \"\(escapeJSON(error))\"}"
        }

        guard let responseData = result.data else {
            return "{\"error\": \"Failed to get image results\"}"
        }

        // Step 4: Parse JSON response
        struct ImageAPIResult: Decodable {
            let image: String?
            let thumbnail: String?
            let title: String?
            let url: String?
            let width: Int?
            let height: Int?
        }

        struct ImageAPIResponse: Decodable {
            let results: [ImageAPIResult]?
        }

        guard let apiResponse = try? JSONDecoder().decode(ImageAPIResponse.self, from: responseData),
            let results = apiResponse.results, !results.isEmpty
        else {
            return "{\"results\": [], \"query\": \"\(escapeJSON(input.query))\", \"type\": \"images\", \"count\": 0}"
        }

        // Step 5: Format the results
        let limitedResults = Array(results.prefix(maxResults))
        let imagesJSON = limitedResults.compactMap { img -> String? in
            guard let imageUrl = img.image else { return nil }
            let title = img.title ?? ""
            let sourceUrl = img.url ?? ""
            let thumbnailUrl = img.thumbnail ?? imageUrl
            let width = img.width ?? 0
            let height = img.height ?? 0

            return
                "{\"title\": \"\(escapeJSON(title))\", \"image_url\": \"\(escapeJSON(imageUrl))\", \"thumbnail_url\": \"\(escapeJSON(thumbnailUrl))\", \"source_url\": \"\(escapeJSON(sourceUrl))\", \"width\": \(width), \"height\": \(height)}"
        }.joined(separator: ",")

        return
            "{\"results\": [\(imagesJSON)], \"query\": \"\(escapeJSON(input.query))\", \"type\": \"images\", \"count\": \(limitedResults.count)}"
    }
}

// MARK: - Plugin Context

private class PluginContext {
    let searchTool = SearchTool()
    let searchNewsTool = SearchNewsTool()
    let searchImagesTool = SearchImagesTool()
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
              "plugin_id": "osaurus.search",
              "version": "1.0.0",
              "description": "Web search using DuckDuckGo (no API key required)",
              "capabilities": {
                "tools": [
                  {"id": "search", "description": "Search the web using DuckDuckGo", "parameters": {"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"number"},"region":{"type":"string"}},"required":["query"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "search_news", "description": "Search for news using DuckDuckGo", "parameters": {"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"number"},"timelimit":{"type":"string"}},"required":["query"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "search_images", "description": "Search for images using DuckDuckGo", "parameters": {"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"number"},"size":{"type":"string"},"type":{"type":"string"}},"required":["query"]}, "requirements": [], "permission_policy": "ask"}
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
        case ctx.searchTool.name:
            return makeCString(ctx.searchTool.run(args: payload))
        case ctx.searchNewsTool.name:
            return makeCString(ctx.searchNewsTool.run(args: payload))
        case ctx.searchImagesTool.name:
            return makeCString(ctx.searchImagesTool.run(args: payload))
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
