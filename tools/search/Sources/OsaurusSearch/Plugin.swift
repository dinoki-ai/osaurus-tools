import Foundation

// MARK: - HTTP Helper

/// User agents to rotate through for requests
private let userAgents = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
]

/// Rate limit detection patterns in HTML responses
private let rateLimitPatterns = [
    "you appear to be a bot",
    "unusual traffic",
    "rate limit",
    "too many requests",
    "please try again later",
    "captcha",
    "blocked",
    "access denied",
]

/// Check if a response indicates rate limiting
private func isRateLimited(response: HTTPURLResponse?, data: Data?) -> Bool {
    // Check HTTP status code
    if let statusCode = response?.statusCode {
        if statusCode == 429 || statusCode == 403 || statusCode == 503 {
            return true
        }
    }

    // Check response body for rate limit indicators
    if let data = data, let html = String(data: data, encoding: .utf8) {
        let lowercased = html.lowercased()
        for pattern in rateLimitPatterns {
            if lowercased.contains(pattern) {
                return true
            }
        }
    }

    return false
}

/// Add jitter to a delay to avoid thundering herd
private func addJitter(to delay: TimeInterval) -> TimeInterval {
    let jitter = Double.random(in: 0.0...0.5)
    return delay * (1.0 + jitter)
}

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

    // Set default headers to mimic a browser with random user agent
    let userAgent = userAgents.randomElement() ?? userAgents[0]
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")

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

/// Perform request with retry logic and exponential backoff
private func performRequestWithRetry(
    url: String,
    headers: [String: String]? = nil,
    timeout: TimeInterval = 30,
    maxRetries: Int = 3
) -> (data: Data?, response: HTTPURLResponse?, error: String?, rateLimited: Bool) {

    var lastData: Data?
    var lastResponse: HTTPURLResponse?
    var lastError: String?
    var wasRateLimited = false

    for attempt in 0..<maxRetries {
        let result = performRequest(url: url, headers: headers, timeout: timeout)
        lastData = result.data
        lastResponse = result.response
        lastError = result.error

        // Check for rate limiting
        if isRateLimited(response: result.response, data: result.data) {
            wasRateLimited = true

            // Don't retry on last attempt
            if attempt < maxRetries - 1 {
                // Exponential backoff: 1s, 2s, 4s with jitter
                let baseDelay = pow(2.0, Double(attempt))
                let delay = addJitter(to: baseDelay)
                Thread.sleep(forTimeInterval: delay)
                continue
            }
        }

        // If we got a successful response (2xx status), return it
        if let statusCode = result.response?.statusCode, (200..<300).contains(statusCode) {
            return (result.data, result.response, result.error, false)
        }

        // If there was a network error, retry with backoff
        if result.error != nil && attempt < maxRetries - 1 {
            let baseDelay = pow(2.0, Double(attempt))
            let delay = addJitter(to: baseDelay)
            Thread.sleep(forTimeInterval: delay)
            continue
        }

        // Got a response (even if not 2xx), return it
        if result.response != nil {
            return (result.data, result.response, result.error, wasRateLimited)
        }
    }

    return (lastData, lastResponse, lastError, wasRateLimited)
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

// MARK: - Search Provider Protocol

/// Result from a search provider
private struct SearchProviderResult {
    let results: [SearchResult]
    let rateLimited: Bool
    let error: String?
}

/// Protocol for search providers
private protocol SearchProvider {
    var name: String { get }
    func search(query: String, maxResults: Int, region: String?) -> SearchProviderResult
    func searchNews(query: String, maxResults: Int, timelimit: String?) -> SearchProviderResult
}

// MARK: - DuckDuckGo Search Provider

private class DDGSearchProvider: SearchProvider {
    let name = "DuckDuckGo"

    func search(query: String, maxResults: Int, region: String?) -> SearchProviderResult {
        let regionCode = region ?? "wt-wt"
        let searchUrl = "https://html.duckduckgo.com/html/?q=\(urlEncode(query))&kl=\(regionCode)"

        let result = performRequestWithRetry(url: searchUrl)

        if result.rateLimited {
            return SearchProviderResult(results: [], rateLimited: true, error: "Rate limited by DuckDuckGo")
        }

        if let error = result.error {
            return SearchProviderResult(results: [], rateLimited: false, error: error)
        }

        guard let responseData = result.data,
            let html = String(data: responseData, encoding: .utf8)
        else {
            return SearchProviderResult(results: [], rateLimited: false, error: "Failed to get search results")
        }

        let results = parseDDGResults(html: html, maxResults: maxResults)
        return SearchProviderResult(results: results, rateLimited: false, error: nil)
    }

    func searchNews(query: String, maxResults: Int, timelimit: String?) -> SearchProviderResult {
        var searchUrl = "https://html.duckduckgo.com/html/?q=\(urlEncode(query))&iar=news"
        if let timelimit = timelimit {
            searchUrl += "&df=\(timelimit)"
        }

        let result = performRequestWithRetry(url: searchUrl)

        if result.rateLimited {
            return SearchProviderResult(results: [], rateLimited: true, error: "Rate limited by DuckDuckGo")
        }

        if let error = result.error {
            return SearchProviderResult(results: [], rateLimited: false, error: error)
        }

        guard let responseData = result.data,
            let html = String(data: responseData, encoding: .utf8)
        else {
            return SearchProviderResult(results: [], rateLimited: false, error: "Failed to get news results")
        }

        let results = parseDDGResults(html: html, maxResults: maxResults)
        return SearchProviderResult(results: results, rateLimited: false, error: nil)
    }
}

// MARK: - Brave Search Provider

private class BraveSearchProvider: SearchProvider {
    let name = "Brave"

    func search(query: String, maxResults: Int, region: String?) -> SearchProviderResult {
        let searchUrl = "https://search.brave.com/search?q=\(urlEncode(query))&source=web"

        let result = performRequestWithRetry(url: searchUrl)

        if result.rateLimited {
            return SearchProviderResult(results: [], rateLimited: true, error: "Rate limited by Brave Search")
        }

        if let error = result.error {
            return SearchProviderResult(results: [], rateLimited: false, error: error)
        }

        guard let responseData = result.data,
            let html = String(data: responseData, encoding: .utf8)
        else {
            return SearchProviderResult(results: [], rateLimited: false, error: "Failed to get search results")
        }

        let results = parseBraveResults(html: html, maxResults: maxResults)
        return SearchProviderResult(results: results, rateLimited: false, error: nil)
    }

    func searchNews(query: String, maxResults: Int, timelimit: String?) -> SearchProviderResult {
        var searchUrl = "https://search.brave.com/news?q=\(urlEncode(query))"
        if let timelimit = timelimit {
            // Brave uses freshness parameter: pd (past day), pw (past week), pm (past month)
            let freshnessMap = ["d": "pd", "w": "pw", "m": "pm"]
            if let freshness = freshnessMap[timelimit] {
                searchUrl += "&tf=\(freshness)"
            }
        }

        let result = performRequestWithRetry(url: searchUrl)

        if result.rateLimited {
            return SearchProviderResult(results: [], rateLimited: true, error: "Rate limited by Brave Search")
        }

        if let error = result.error {
            return SearchProviderResult(results: [], rateLimited: false, error: error)
        }

        guard let responseData = result.data,
            let html = String(data: responseData, encoding: .utf8)
        else {
            return SearchProviderResult(results: [], rateLimited: false, error: "Failed to get news results")
        }

        let results = parseBraveResults(html: html, maxResults: maxResults)
        return SearchProviderResult(results: results, rateLimited: false, error: nil)
    }

    private func parseBraveResults(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Brave search results are in <div class="snippet" data-type="web">
        // with <a class="result-header"> containing the URL and title
        // and <p class="snippet-description"> containing the snippet

        // Pattern 1: Look for result items with data-type="web"
        let snippetPattern =
            "<div[^>]*class=\"[^\"]*snippet[^\"]*\"[^>]*data-type=\"web\"[^>]*>([\\s\\S]*?)</div>\\s*</div>"

        if let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = snippetRegex.matches(in: html, range: range)

            for match in matches.prefix(maxResults) {
                if let contentRange = Range(match.range(at: 1), in: html) {
                    let content = String(html[contentRange])

                    // Extract URL and title from result-header link
                    let headerPattern =
                        "<a[^>]*class=\"[^\"]*result-header[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>"
                    if let headerRegex = try? NSRegularExpression(pattern: headerPattern, options: .caseInsensitive) {
                        let contentRange = NSRange(content.startIndex..., in: content)
                        if let headerMatch = headerRegex.firstMatch(in: content, range: contentRange) {
                            if let urlRange = Range(headerMatch.range(at: 1), in: content),
                                let titleRange = Range(headerMatch.range(at: 2), in: content)
                            {
                                let url = decodeHTMLEntities(String(content[urlRange]))
                                let title = stripHTML(String(content[titleRange]))

                                // Extract snippet
                                var snippet = ""
                                let snippetDescPattern =
                                    "<p[^>]*class=\"[^\"]*snippet-description[^\"]*\"[^>]*>([\\s\\S]*?)</p>"
                                if let descRegex = try? NSRegularExpression(
                                    pattern: snippetDescPattern, options: .caseInsensitive)
                                {
                                    if let descMatch = descRegex.firstMatch(in: content, range: contentRange) {
                                        if let descRange = Range(descMatch.range(at: 1), in: content) {
                                            snippet = stripHTML(String(content[descRange]))
                                        }
                                    }
                                }

                                if !url.isEmpty && !title.isEmpty {
                                    results.append(SearchResult(title: title, url: url, snippet: snippet))
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fallback: simpler pattern for Brave results
        if results.isEmpty {
            // Try to find links with titles in search results
            let simplePattern = "<a[^>]*href=\"(https?://[^\"]+)\"[^>]*>\\s*<span[^>]*>([^<]+)</span>"
            if let regex = try? NSRegularExpression(pattern: simplePattern, options: .caseInsensitive) {
                let range = NSRange(html.startIndex..., in: html)
                let matches = regex.matches(in: html, range: range)

                for match in matches.prefix(maxResults * 2) {
                    if let urlRange = Range(match.range(at: 1), in: html),
                        let titleRange = Range(match.range(at: 2), in: html)
                    {
                        let url = String(html[urlRange])
                        let title = stripHTML(String(html[titleRange]))

                        // Skip Brave internal links
                        if url.contains("brave.com") && !url.contains("search.brave.com/search") {
                            continue
                        }

                        if title.count >= 3 && !url.isEmpty {
                            results.append(SearchResult(title: title, url: url, snippet: ""))
                            if results.count >= maxResults { break }
                        }
                    }
                }
            }
        }

        return results
    }
}

// MARK: - Bing Search Provider

private class BingSearchProvider: SearchProvider {
    let name = "Bing"

    func search(query: String, maxResults: Int, region: String?) -> SearchProviderResult {
        let searchUrl = "https://www.bing.com/search?q=\(urlEncode(query))&count=\(maxResults)"

        let result = performRequestWithRetry(url: searchUrl)

        if result.rateLimited {
            return SearchProviderResult(results: [], rateLimited: true, error: "Rate limited by Bing")
        }

        if let error = result.error {
            return SearchProviderResult(results: [], rateLimited: false, error: error)
        }

        guard let responseData = result.data,
            let html = String(data: responseData, encoding: .utf8)
        else {
            return SearchProviderResult(results: [], rateLimited: false, error: "Failed to get search results")
        }

        let results = parseBingResults(html: html, maxResults: maxResults)
        return SearchProviderResult(results: results, rateLimited: false, error: nil)
    }

    func searchNews(query: String, maxResults: Int, timelimit: String?) -> SearchProviderResult {
        var searchUrl = "https://www.bing.com/news/search?q=\(urlEncode(query))"
        if let timelimit = timelimit {
            // Bing uses qft parameter for time filter
            let timeMap = ["d": "interval%3d%227%22", "w": "interval%3d%228%22", "m": "interval%3d%229%22"]
            if let interval = timeMap[timelimit] {
                searchUrl += "&qft=\(interval)"
            }
        }

        let result = performRequestWithRetry(url: searchUrl)

        if result.rateLimited {
            return SearchProviderResult(results: [], rateLimited: true, error: "Rate limited by Bing")
        }

        if let error = result.error {
            return SearchProviderResult(results: [], rateLimited: false, error: error)
        }

        guard let responseData = result.data,
            let html = String(data: responseData, encoding: .utf8)
        else {
            return SearchProviderResult(results: [], rateLimited: false, error: "Failed to get news results")
        }

        let results = parseBingNewsResults(html: html, maxResults: maxResults)
        return SearchProviderResult(results: results, rateLimited: false, error: nil)
    }

    private func parseBingResults(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Bing results are typically in <li class="b_algo"> elements
        // with <h2><a href="...">title</a></h2> and <p class="b_lineclamp...">snippet</p>

        // Pattern for Bing organic results
        let algoPattern = "<li[^>]*class=\"b_algo\"[^>]*>([\\s\\S]*?)</li>"

        if let algoRegex = try? NSRegularExpression(pattern: algoPattern, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = algoRegex.matches(in: html, range: range)

            for match in matches.prefix(maxResults) {
                if let contentRange = Range(match.range(at: 1), in: html) {
                    let content = String(html[contentRange])

                    // Extract URL and title from h2 > a
                    let linkPattern = "<h2[^>]*>\\s*<a[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>"
                    if let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: .caseInsensitive) {
                        let contentRange = NSRange(content.startIndex..., in: content)
                        if let linkMatch = linkRegex.firstMatch(in: content, range: contentRange) {
                            if let urlRange = Range(linkMatch.range(at: 1), in: content),
                                let titleRange = Range(linkMatch.range(at: 2), in: content)
                            {
                                let url = decodeHTMLEntities(String(content[urlRange]))
                                let title = stripHTML(String(content[titleRange]))

                                // Skip Bing internal URLs
                                if url.contains("bing.com") || url.contains("microsoft.com/bing") {
                                    continue
                                }

                                // Extract snippet
                                var snippet = ""
                                let snippetPattern = "<p[^>]*class=\"[^\"]*b_lineclamp[^\"]*\"[^>]*>([\\s\\S]*?)</p>"
                                if let snippetRegex = try? NSRegularExpression(
                                    pattern: snippetPattern, options: .caseInsensitive)
                                {
                                    if let snippetMatch = snippetRegex.firstMatch(in: content, range: contentRange) {
                                        if let snippetRange = Range(snippetMatch.range(at: 1), in: content) {
                                            snippet = stripHTML(String(content[snippetRange]))
                                        }
                                    }
                                }

                                // Alternative snippet pattern
                                if snippet.isEmpty {
                                    let altSnippetPattern =
                                        "<div[^>]*class=\"[^\"]*b_caption[^\"]*\"[^>]*>([\\s\\S]*?)</div>"
                                    if let altRegex = try? NSRegularExpression(
                                        pattern: altSnippetPattern, options: .caseInsensitive)
                                    {
                                        if let altMatch = altRegex.firstMatch(in: content, range: contentRange) {
                                            if let altRange = Range(altMatch.range(at: 1), in: content) {
                                                snippet = stripHTML(String(content[altRange]))
                                            }
                                        }
                                    }
                                }

                                if !url.isEmpty && !title.isEmpty {
                                    results.append(SearchResult(title: title, url: url, snippet: snippet))
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fallback: simpler link extraction
        if results.isEmpty {
            let simplePattern = "<a[^>]*href=\"(https?://[^\"]+)\"[^>]*h=\"[^\"]*\"[^>]*>([^<]+)</a>"
            if let regex = try? NSRegularExpression(pattern: simplePattern, options: .caseInsensitive) {
                let range = NSRange(html.startIndex..., in: html)
                let matches = regex.matches(in: html, range: range)

                for match in matches.prefix(maxResults * 2) {
                    if let urlRange = Range(match.range(at: 1), in: html),
                        let titleRange = Range(match.range(at: 2), in: html)
                    {
                        let url = String(html[urlRange])
                        let title = stripHTML(String(html[titleRange]))

                        // Skip Bing/Microsoft internal links
                        if url.contains("bing.com") || url.contains("microsoft.com") {
                            continue
                        }

                        if title.count >= 3 {
                            results.append(SearchResult(title: title, url: url, snippet: ""))
                            if results.count >= maxResults { break }
                        }
                    }
                }
            }
        }

        return results
    }

    private func parseBingNewsResults(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Bing news results are in <div class="news-card"> or similar
        let newsPattern = "<a[^>]*class=\"[^\"]*title[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>"

        if let regex = try? NSRegularExpression(pattern: newsPattern, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, range: range)

            for match in matches.prefix(maxResults) {
                if let urlRange = Range(match.range(at: 1), in: html),
                    let titleRange = Range(match.range(at: 2), in: html)
                {
                    let url = decodeHTMLEntities(String(html[urlRange]))
                    let title = stripHTML(String(html[titleRange]))

                    if !url.contains("bing.com") && !title.isEmpty {
                        results.append(SearchResult(title: title, url: url, snippet: ""))
                    }
                }
            }
        }

        // Fallback to regular results parser
        if results.isEmpty {
            results = parseBingResults(html: html, maxResults: maxResults)
        }

        return results
    }
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

// MARK: - Provider Cascade Helper

/// Result of a cascaded search across multiple providers
private struct CascadeResult {
    let results: [SearchResult]
    let successfulProvider: String?
    let warning: String?
    let allFailed: Bool
}

/// Get ordered list of search providers
private func getSearchProviders() -> [SearchProvider] {
    return [
        DDGSearchProvider(),
        BraveSearchProvider(),
        BingSearchProvider(),
    ]
}

/// Cascade through providers for web search until one succeeds
private func cascadeSearch(query: String, maxResults: Int, region: String?) -> CascadeResult {
    let providers = getSearchProviders()
    var collectedResults: [SearchResult] = []
    var failedProviders: [String] = []
    var successfulProvider: String?

    for provider in providers {
        let result = provider.search(query: query, maxResults: maxResults, region: region)

        if result.rateLimited {
            failedProviders.append(provider.name)
            continue
        }

        if result.error != nil && result.results.isEmpty {
            failedProviders.append(provider.name)
            continue
        }

        if !result.results.isEmpty {
            collectedResults = result.results
            successfulProvider = provider.name
            break
        }
    }

    // Determine warning message
    var warning: String?
    if !failedProviders.isEmpty && successfulProvider != nil {
        warning =
            "Some search providers were unavailable (\(failedProviders.joined(separator: ", "))). Results may be limited."
    } else if successfulProvider == nil && !failedProviders.isEmpty {
        warning = "All search providers are currently unavailable. Please try again later."
    }

    return CascadeResult(
        results: collectedResults,
        successfulProvider: successfulProvider,
        warning: warning,
        allFailed: successfulProvider == nil && !failedProviders.isEmpty
    )
}

/// Cascade through providers for news search until one succeeds
private func cascadeNewsSearch(query: String, maxResults: Int, timelimit: String?) -> CascadeResult {
    let providers = getSearchProviders()
    var collectedResults: [SearchResult] = []
    var failedProviders: [String] = []
    var successfulProvider: String?

    for provider in providers {
        let result = provider.searchNews(query: query, maxResults: maxResults, timelimit: timelimit)

        if result.rateLimited {
            failedProviders.append(provider.name)
            continue
        }

        if result.error != nil && result.results.isEmpty {
            failedProviders.append(provider.name)
            continue
        }

        if !result.results.isEmpty {
            collectedResults = result.results
            successfulProvider = provider.name
            break
        }
    }

    // Determine warning message
    var warning: String?
    if !failedProviders.isEmpty && successfulProvider != nil {
        warning =
            "Some search providers were unavailable (\(failedProviders.joined(separator: ", "))). Results may be limited."
    } else if successfulProvider == nil && !failedProviders.isEmpty {
        warning = "All search providers are currently unavailable. Please try again later."
    }

    return CascadeResult(
        results: collectedResults,
        successfulProvider: successfulProvider,
        warning: warning,
        allFailed: successfulProvider == nil && !failedProviders.isEmpty
    )
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
        let region = input.region

        // Use provider cascade for resilience
        let cascadeResult = cascadeSearch(query: input.query, maxResults: maxResults, region: region)

        // Build response JSON
        let resultsJSON = cascadeResult.results.map { r in
            "{\"title\": \"\(escapeJSON(r.title))\", \"url\": \"\(escapeJSON(r.url))\", \"snippet\": \"\(escapeJSON(r.snippet))\"}"
        }.joined(separator: ",")

        var response =
            "{\"results\": [\(resultsJSON)], \"query\": \"\(escapeJSON(input.query))\", \"count\": \(cascadeResult.results.count)"

        // Add provider info
        if let provider = cascadeResult.successfulProvider {
            response += ", \"provider\": \"\(escapeJSON(provider))\""
        }

        // Add warning if any providers failed
        if let warning = cascadeResult.warning {
            response += ", \"warning\": \"\(escapeJSON(warning))\""
        }

        // Add message for empty results
        if cascadeResult.results.isEmpty {
            if cascadeResult.allFailed {
                response +=
                    ", \"message\": \"All search providers are currently rate limited. Please try again later.\""
            } else {
                response += ", \"message\": \"No results found\""
            }
        }

        response += "}"
        return response
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

        // Use provider cascade for resilience
        let cascadeResult = cascadeNewsSearch(query: input.query, maxResults: maxResults, timelimit: input.timelimit)

        // Build response JSON
        let resultsJSON = cascadeResult.results.map { r in
            "{\"title\": \"\(escapeJSON(r.title))\", \"url\": \"\(escapeJSON(r.url))\", \"snippet\": \"\(escapeJSON(r.snippet))\"}"
        }.joined(separator: ",")

        var response =
            "{\"results\": [\(resultsJSON)], \"query\": \"\(escapeJSON(input.query))\", \"type\": \"news\", \"count\": \(cascadeResult.results.count)"

        // Add provider info
        if let provider = cascadeResult.successfulProvider {
            response += ", \"provider\": \"\(escapeJSON(provider))\""
        }

        // Add warning if any providers failed
        if let warning = cascadeResult.warning {
            response += ", \"warning\": \"\(escapeJSON(warning))\""
        }

        // Add message for empty results
        if cascadeResult.results.isEmpty {
            if cascadeResult.allFailed {
                response +=
                    ", \"message\": \"All search providers are currently rate limited. Please try again later.\""
            } else {
                response += ", \"message\": \"No results found\""
            }
        }

        response += "}"
        return response
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
