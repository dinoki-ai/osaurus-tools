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
    
    // Track pending network requests for networkidle detection
    private var pendingRequests = 0
    private var networkIdleSemaphore: DispatchSemaphore?
    
    // Element ref counter - increments with each snapshot
    private var refCounter = 0

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
        
        // Set up user agent to appear as a real browser
        config.applicationNameForUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        // Create a headless webview (no window needed)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.navigationDelegate = self

        // Enable JavaScript
        if #available(macOS 14.0, *) {
            webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
    }

    // MARK: - Navigation

    enum WaitUntil: String {
        case load = "load"
        case networkidle = "networkidle"
        case domstable = "domstable"
    }

    func navigate(to urlString: String, timeout: TimeInterval = 30, waitUntil: WaitUntil = .load) -> (success: Bool, error: String?) {
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

        // Additional wait strategies
        switch waitUntil {
        case .load:
            // Already done - didFinish was called
            break
        case .networkidle:
            // Wait for network to be idle (no requests for 500ms)
            waitForNetworkIdle(timeout: timeout)
        case .domstable:
            // Wait for DOM to stabilize
            waitForDOMStable(timeout: timeout)
        }

        return (true, nil)
    }

    private func waitForNetworkIdle(timeout: TimeInterval) {
        // Simple implementation: wait a bit for dynamic content
        Thread.sleep(forTimeInterval: 0.5)
        
        // Check if there are pending XHR/fetch requests
        let script = """
        (function() {
            return window.performance.getEntriesByType('resource')
                .filter(r => r.initiatorType === 'fetch' || r.initiatorType === 'xmlhttprequest')
                .filter(r => r.responseEnd === 0).length;
        })()
        """
        
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            let result = evaluateJavaScript(script)
            if let pending = result.result as? Int, pending == 0 {
                Thread.sleep(forTimeInterval: 0.3) // Extra buffer
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func waitForDOMStable(timeout: TimeInterval) {
        // Use MutationObserver to detect DOM changes
        let script = """
        new Promise((resolve) => {
            let timeout;
            const observer = new MutationObserver(() => {
                clearTimeout(timeout);
                timeout = setTimeout(() => {
                    observer.disconnect();
                    resolve(true);
                }, 300);
            });
            observer.observe(document.body, { childList: true, subtree: true, attributes: true });
            timeout = setTimeout(() => {
                observer.disconnect();
                resolve(true);
            }, 300);
        });
        """
        
        _ = evaluateJavaScript(script, timeout: timeout)
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

    // MARK: - Snapshot (Core Feature)

    struct SnapshotOptions {
        var filter: String = "all"  // all, inputs, buttons, links, forms
        var maxElements: Int = 100
        var visibleOnly: Bool = true
    }

    func takeSnapshot(options: SnapshotOptions = SnapshotOptions()) -> String {
        // Reset ref counter for each snapshot
        refCounter = 0
        
        let filterCondition: String
        switch options.filter {
        case "inputs":
            filterCondition = "el.matches('input, textarea, select, [contenteditable=\"true\"]')"
        case "buttons":
            filterCondition = "el.matches('button, input[type=\"button\"], input[type=\"submit\"], [role=\"button\"]')"
        case "links":
            filterCondition = "el.matches('a[href]')"
        case "forms":
            filterCondition = "el.matches('form, input, textarea, select, button')"
        default:
            filterCondition = "true"
        }

        let visibilityCheck = options.visibleOnly ? """
            const rect = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
            if (rect.width === 0 && rect.height === 0) return false;
            return true;
        """ : "return true;"

        let script = """
        (function() {
            const maxElements = \(options.maxElements);
            const results = [];
            let refId = 0;
            
            // Store refs in a global map for later retrieval
            if (!window.__osaurus_refs) {
                window.__osaurus_refs = new Map();
            }
            window.__osaurus_refs.clear();
            
            function isVisible(el) {
                \(visibilityCheck)
            }
            
            function isInteractive(el) {
                const tag = el.tagName.toLowerCase();
                const role = el.getAttribute('role');
                const tabIndex = el.getAttribute('tabindex');
                
                // Standard interactive elements
                if (['a', 'button', 'input', 'textarea', 'select', 'details', 'summary'].includes(tag)) return true;
                
                // ARIA roles
                if (['button', 'link', 'menuitem', 'option', 'radio', 'checkbox', 'tab', 'textbox', 'combobox', 'listbox', 'menu', 'menubar', 'slider', 'spinbutton', 'switch'].includes(role)) return true;
                
                // Clickable elements
                if (el.onclick || el.getAttribute('onclick')) return true;
                if (tabIndex && tabIndex !== '-1') return true;
                
                // Contenteditable
                if (el.getAttribute('contenteditable') === 'true') return true;
                
                return false;
            }
            
            function getElementType(el) {
                const tag = el.tagName.toLowerCase();
                const type = el.getAttribute('type');
                const role = el.getAttribute('role');
                
                if (tag === 'a') return 'link';
                if (tag === 'button' || role === 'button') return 'button';
                if (tag === 'input') {
                    if (type === 'checkbox') return 'checkbox';
                    if (type === 'radio') return 'radio';
                    if (type === 'submit') return 'submit';
                    if (type === 'file') return 'file';
                    return 'input';
                }
                if (tag === 'textarea') return 'textarea';
                if (tag === 'select') return 'select';
                if (tag === 'img') return 'img';
                if (role) return role;
                return tag;
            }
            
            function truncate(str, len) {
                if (!str) return '';
                str = str.trim().replace(/\\s+/g, ' ');
                return str.length > len ? str.substring(0, len) + '...' : str;
            }
            
            function getElementText(el) {
                const tag = el.tagName.toLowerCase();
                
                // For inputs, use placeholder or aria-label
                if (tag === 'input' || tag === 'textarea') {
                    return el.placeholder || el.getAttribute('aria-label') || el.name || '';
                }
                
                // For images, use alt text
                if (tag === 'img') {
                    return el.alt || el.title || '';
                }
                
                // For other elements, get visible text
                const text = el.innerText || el.textContent || '';
                return text;
            }
            
            function getElementInfo(el) {
                const ref = 'E' + (++refId);
                window.__osaurus_refs.set(ref, el);
                
                const type = getElementType(el);
                const text = truncate(getElementText(el), 50);
                
                let info = { ref, type, text };
                
                // Add relevant attributes
                if (el.name) info.name = el.name;
                if (el.id) info.id = truncate(el.id, 30);
                if (el.value && el.tagName.toLowerCase() !== 'textarea') info.value = truncate(el.value, 30);
                if (el.placeholder) info.placeholder = truncate(el.placeholder, 30);
                if (el.href) info.href = truncate(el.href, 50);
                if (el.checked) info.checked = true;
                if (el.disabled) info.disabled = true;
                if (el.required) info.required = true;
                if (el.getAttribute('aria-label')) info.ariaLabel = truncate(el.getAttribute('aria-label'), 30);
                
                return info;
            }
            
            // Walk the DOM
            const walker = document.createTreeWalker(
                document.body,
                NodeFilter.SHOW_ELEMENT,
                {
                    acceptNode: function(node) {
                        if (!isInteractive(node)) return NodeFilter.FILTER_SKIP;
                        if (!isVisible(node)) return NodeFilter.FILTER_SKIP;
                        if (!(\(filterCondition))) return NodeFilter.FILTER_SKIP;
                        return NodeFilter.FILTER_ACCEPT;
                    }
                }
            );
            
            let el;
            while ((el = walker.nextNode()) && results.length < maxElements) {
                results.push(getElementInfo(el));
            }
            
            return {
                url: window.location.href,
                title: document.title,
                elementCount: results.length,
                hasMore: walker.nextNode() !== null,
                elements: results
            };
        })()
        """

        let result = evaluateJavaScript(script, timeout: 15)
        
        if let error = result.error {
            return "Error: \(error)"
        }
        
        guard let data = result.result as? [String: Any] else {
            return "Error: Failed to parse snapshot"
        }
        
        return formatSnapshot(data)
    }

    private func formatSnapshot(_ data: [String: Any]) -> String {
        var output = ""
        
        // Header
        let title = data["title"] as? String ?? ""
        let url = data["url"] as? String ?? ""
        let hasMore = data["hasMore"] as? Bool ?? false
        
        output += "- page: \(title)\n"
        output += "- url: \(url)\n\n"
        
        // Elements
        guard let elements = data["elements"] as? [[String: Any]] else {
            return output + "(no interactive elements found)"
        }
        
        for element in elements {
            let ref = element["ref"] as? String ?? ""
            let type = element["type"] as? String ?? ""
            let text = element["text"] as? String ?? ""
            
            var line = "[\(ref)] \(type)"
            
            if !text.isEmpty {
                line += " \"\(text)\""
            }
            
            // Add key attributes inline
            var attrs: [String] = []
            if let name = element["name"] as? String, !name.isEmpty {
                attrs.append("name=\"\(name)\"")
            }
            if let placeholder = element["placeholder"] as? String, !placeholder.isEmpty {
                attrs.append("placeholder=\"\(placeholder)\"")
            }
            if let href = element["href"] as? String, !href.isEmpty, type == "link" {
                attrs.append("href=\"\(href)\"")
            }
            if let value = element["value"] as? String, !value.isEmpty {
                attrs.append("value=\"\(value)\"")
            }
            if element["checked"] as? Bool == true {
                attrs.append("checked")
            }
            if element["disabled"] as? Bool == true {
                attrs.append("disabled")
            }
            if element["required"] as? Bool == true {
                attrs.append("required")
            }
            
            if !attrs.isEmpty {
                line += " " + attrs.joined(separator: " ")
            }
            
            output += line + "\n"
        }
        
        if hasMore {
            output += "\n... (more elements available, use filter or increase max_elements)"
        }
        
        return output
    }

    // MARK: - Element Interactions (Ref-based)

    func clickElement(ref: String?, selector: String?) -> (success: Bool, error: String?) {
        let script: String
        
        if let ref = ref {
            script = """
            (function() {
                const el = window.__osaurus_refs?.get('\(ref)');
                if (!el) return {success: false, error: 'Element ref not found. Call browser_snapshot first.'};
                if (!document.body.contains(el)) return {success: false, error: 'Element no longer in DOM. Call browser_snapshot to refresh.'};
                el.click();
                return {success: true};
            })()
            """
        } else if let selector = selector {
            script = """
            (function() {
                const el = document.querySelector('\(escapeSelector(selector))');
                if (!el) return {success: false, error: 'Element not found: \(escapeSelector(selector))'};
                el.click();
                return {success: true};
            })()
            """
        } else {
            return (false, "Either ref or selector must be provided")
        }
        
        let result = evaluateJavaScript(script)
        
        if let error = result.error {
            return (false, error)
        }
        
        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }
        
        return (false, "Unknown error")
    }

    func typeText(ref: String?, selector: String?, text: String, clear: Bool = true, submit: Bool = false) -> (success: Bool, error: String?) {
        let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        
        let getElementScript: String
        if let ref = ref {
            getElementScript = "window.__osaurus_refs?.get('\(ref)')"
        } else if let selector = selector {
            getElementScript = "document.querySelector('\(escapeSelector(selector))')"
        } else {
            return (false, "Either ref or selector must be provided")
        }
        
        let script = """
        (function() {
            const el = \(getElementScript);
            if (!el) return {success: false, error: 'Element not found'};
            if (!document.body.contains(el)) return {success: false, error: 'Element no longer in DOM'};
            
            el.focus();
            if (\(clear)) el.value = '';
            el.value += '\(escapedText)';
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            
            if (\(submit)) {
                const form = el.closest('form');
                if (form) {
                    form.submit();
                } else {
                    el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', bubbles: true}));
                }
            }
            
            return {success: true};
        })()
        """
        
        let result = evaluateJavaScript(script)
        
        if let error = result.error {
            return (false, error)
        }
        
        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }
        
        return (false, "Unknown error")
    }

    func selectOption(ref: String?, selector: String?, values: [String]) -> (success: Bool, error: String?) {
        let valuesJSON = values.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")
        
        let getElementScript: String
        if let ref = ref {
            getElementScript = "window.__osaurus_refs?.get('\(ref)')"
        } else if let selector = selector {
            getElementScript = "document.querySelector('\(escapeSelector(selector))')"
        } else {
            return (false, "Either ref or selector must be provided")
        }
        
        let script = """
        (function() {
            const el = \(getElementScript);
            if (!el) return {success: false, error: 'Element not found'};
            if (el.tagName.toLowerCase() !== 'select') return {success: false, error: 'Element is not a select'};
            
            const values = [\(valuesJSON)];
            for (const opt of el.options) {
                opt.selected = values.includes(opt.value) || values.includes(opt.text);
            }
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return {success: true};
        })()
        """
        
        let result = evaluateJavaScript(script)
        
        if let error = result.error {
            return (false, error)
        }
        
        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }
        
        return (false, "Unknown error")
    }

    func hoverElement(ref: String?, selector: String?) -> (success: Bool, error: String?) {
        let getElementScript: String
        if let ref = ref {
            getElementScript = "window.__osaurus_refs?.get('\(ref)')"
        } else if let selector = selector {
            getElementScript = "document.querySelector('\(escapeSelector(selector))')"
        } else {
            return (false, "Either ref or selector must be provided")
        }
        
        let script = """
        (function() {
            const el = \(getElementScript);
            if (!el) return {success: false, error: 'Element not found'};
            
            const rect = el.getBoundingClientRect();
            const x = rect.left + rect.width / 2;
            const y = rect.top + rect.height / 2;
            
            el.dispatchEvent(new MouseEvent('mouseenter', {bubbles: true, clientX: x, clientY: y}));
            el.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, clientX: x, clientY: y}));
            el.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, clientX: x, clientY: y}));
            
            return {success: true};
        })()
        """
        
        let result = evaluateJavaScript(script)
        
        if let error = result.error {
            return (false, error)
        }
        
        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }
        
        return (false, "Unknown error")
    }

    // MARK: - Scroll

    func scroll(direction: String? = nil, ref: String? = nil, x: Int? = nil, y: Int? = nil) -> (success: Bool, error: String?) {
        let script: String
        
        if let ref = ref {
            // Scroll to element
            script = """
            (function() {
                const el = window.__osaurus_refs?.get('\(ref)');
                if (!el) return {success: false, error: 'Element ref not found'};
                el.scrollIntoView({behavior: 'smooth', block: 'center'});
                return {success: true};
            })()
            """
        } else if let direction = direction {
            // Scroll by direction
            let scrollAmount: (x: Int, y: Int)
            switch direction.lowercased() {
            case "up": scrollAmount = (0, -400)
            case "down": scrollAmount = (0, 400)
            case "left": scrollAmount = (-400, 0)
            case "right": scrollAmount = (400, 0)
            default: scrollAmount = (0, 400)
            }
            script = """
            (function() {
                window.scrollBy({left: \(scrollAmount.x), top: \(scrollAmount.y), behavior: 'smooth'});
                return {success: true};
            })()
            """
        } else if let x = x, let y = y {
            // Scroll to position
            script = """
            (function() {
                window.scrollTo({left: \(x), top: \(y), behavior: 'smooth'});
                return {success: true};
            })()
            """
        } else {
            return (false, "Provide direction, ref, or x/y coordinates")
        }
        
        let result = evaluateJavaScript(script)
        
        if let error = result.error {
            return (false, error)
        }
        
        // Wait for smooth scroll to complete
        Thread.sleep(forTimeInterval: 0.3)
        
        return (true, nil)
    }

    // MARK: - Press Key

    func pressKey(key: String, modifiers: [String] = []) -> (success: Bool, error: String?) {
        let keyMap: [String: (key: String, code: String, keyCode: Int)] = [
            "enter": ("Enter", "Enter", 13),
            "escape": ("Escape", "Escape", 27),
            "tab": ("Tab", "Tab", 9),
            "backspace": ("Backspace", "Backspace", 8),
            "delete": ("Delete", "Delete", 46),
            "arrowup": ("ArrowUp", "ArrowUp", 38),
            "arrowdown": ("ArrowDown", "ArrowDown", 40),
            "arrowleft": ("ArrowLeft", "ArrowLeft", 37),
            "arrowright": ("ArrowRight", "ArrowRight", 39),
            "home": ("Home", "Home", 36),
            "end": ("End", "End", 35),
            "pageup": ("PageUp", "PageUp", 33),
            "pagedown": ("PageDown", "PageDown", 34),
            "space": (" ", "Space", 32),
        ]
        
        let keyInfo = keyMap[key.lowercased()] ?? (key, "Key\(key.uppercased())", Int(key.unicodeScalars.first?.value ?? 0))
        
        let ctrlKey = modifiers.contains("ctrl") || modifiers.contains("control")
        let shiftKey = modifiers.contains("shift")
        let altKey = modifiers.contains("alt") || modifiers.contains("option")
        let metaKey = modifiers.contains("meta") || modifiers.contains("cmd") || modifiers.contains("command")
        
        let script = """
        (function() {
            const target = document.activeElement || document.body;
            const opts = {
                key: '\(keyInfo.key)',
                code: '\(keyInfo.code)',
                keyCode: \(keyInfo.keyCode),
                which: \(keyInfo.keyCode),
                bubbles: true,
                cancelable: true,
                ctrlKey: \(ctrlKey),
                shiftKey: \(shiftKey),
                altKey: \(altKey),
                metaKey: \(metaKey)
            };
            target.dispatchEvent(new KeyboardEvent('keydown', opts));
            target.dispatchEvent(new KeyboardEvent('keypress', opts));
            target.dispatchEvent(new KeyboardEvent('keyup', opts));
            return {success: true};
        })()
        """
        
        let result = evaluateJavaScript(script)
        
        if let error = result.error {
            return (false, error)
        }
        
        return (true, nil)
    }

    // MARK: - Wait For

    func waitFor(text: String? = nil, textGone: String? = nil, time: TimeInterval? = nil, timeout: TimeInterval = 10) -> (success: Bool, error: String?) {
        if let time = time {
            Thread.sleep(forTimeInterval: time)
            return (true, nil)
        }
        
        let startTime = Date()
        
        if let text = text {
            let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
            while Date().timeIntervalSince(startTime) < timeout {
                let script = "document.body.innerText.includes('\(escapedText)')"
                let result = evaluateJavaScript(script)
                if let found = result.result as? Bool, found {
                    return (true, nil)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return (false, "Timeout waiting for text: \(text)")
        }
        
        if let textGone = textGone {
            let escapedText = textGone.replacingOccurrences(of: "'", with: "\\'")
            while Date().timeIntervalSince(startTime) < timeout {
                let script = "!document.body.innerText.includes('\(escapedText)')"
                let result = evaluateJavaScript(script)
                if let gone = result.result as? Bool, gone {
                    return (true, nil)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return (false, "Timeout waiting for text to disappear: \(textGone)")
        }
        
        return (false, "Provide text, textGone, or time")
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
    
    // MARK: - Helpers
    
    private func escapeSelector(_ selector: String) -> String {
        return selector.replacingOccurrences(of: "'", with: "\\'")
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

        let waitUntil = HeadlessBrowser.WaitUntil(rawValue: input.wait_until ?? "load") ?? .load
        let result = browser.navigate(to: input.url, timeout: input.timeout ?? 30, waitUntil: waitUntil)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true, \"url\": \"\(escapeJSON(browser.currentURL ?? input.url))\", \"title\": \"\(escapeJSON(browser.currentTitle ?? ""))\"}"
    }

    func snapshot(args: String) -> String {
        struct Args: Decodable {
            let filter: String?
            let max_elements: Int?
            let visible_only: Bool?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(filter: nil, max_elements: nil, visible_only: nil)
        }

        var options = HeadlessBrowser.SnapshotOptions()
        if let filter = input.filter { options.filter = filter }
        if let maxElements = input.max_elements { options.maxElements = maxElements }
        if let visibleOnly = input.visible_only { options.visibleOnly = visibleOnly }

        let result = browser.takeSnapshot(options: options)
        return result
    }

    func click(args: String) -> String {
        struct Args: Decodable {
            let ref: String?
            let selector: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: ref or selector\"}"
        }

        let result = browser.clickElement(ref: input.ref, selector: input.selector)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true}"
    }

    func type(args: String) -> String {
        struct Args: Decodable {
            let ref: String?
            let selector: String?
            let text: String
            let clear: Bool?
            let submit: Bool?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: (ref or selector), text\"}"
        }

        let result = browser.typeText(
            ref: input.ref,
            selector: input.selector,
            text: input.text,
            clear: input.clear ?? true,
            submit: input.submit ?? false
        )

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true}"
    }

    func select(args: String) -> String {
        struct Args: Decodable {
            let ref: String?
            let selector: String?
            let values: [String]
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: (ref or selector), values\"}"
        }

        let result = browser.selectOption(ref: input.ref, selector: input.selector, values: input.values)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true}"
    }

    func hover(args: String) -> String {
        struct Args: Decodable {
            let ref: String?
            let selector: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: ref or selector\"}"
        }

        let result = browser.hoverElement(ref: input.ref, selector: input.selector)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true}"
    }

    func scroll(args: String) -> String {
        struct Args: Decodable {
            let direction: String?
            let ref: String?
            let x: Int?
            let y: Int?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: direction, ref, or x/y\"}"
        }

        let result = browser.scroll(direction: input.direction, ref: input.ref, x: input.x, y: input.y)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true}"
    }

    func pressKey(args: String) -> String {
        struct Args: Decodable {
            let key: String
            let modifiers: [String]?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: key\"}"
        }

        let result = browser.pressKey(key: input.key, modifiers: input.modifiers ?? [])

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true}"
    }

    func waitFor(args: String) -> String {
        struct Args: Decodable {
            let text: String?
            let text_gone: String?
            let time: Double?
            let timeout: Double?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: text, text_gone, or time\"}"
        }

        let result = browser.waitFor(
            text: input.text,
            textGone: input.text_gone,
            time: input.time,
            timeout: input.timeout ?? 10
        )

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
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
              "version": "2.0.0",
              "description": "Agent-friendly headless browser with ref-based interactions",
              "capabilities": {
                "tools": [
                  {
                    "id": "browser_navigate",
                    "description": "Navigate to a URL. Use wait_until='networkidle' for SPAs.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "url": {"type": "string", "description": "URL to navigate to"},
                        "wait_until": {"type": "string", "enum": ["load", "networkidle", "domstable"], "description": "When to consider navigation done"},
                        "timeout": {"type": "number", "description": "Timeout in seconds (default 30)"}
                      },
                      "required": ["url"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_snapshot",
                    "description": "Get a structured list of interactive elements on the page. CALL THIS FIRST after navigating. Returns element refs (E1, E2, etc.) that you use in click/type/select. Each element shows its type, text, and key attributes.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "filter": {"type": "string", "enum": ["all", "inputs", "buttons", "links", "forms"], "description": "Filter element types (default: all)"},
                        "max_elements": {"type": "number", "description": "Max elements to return (default: 100)"},
                        "visible_only": {"type": "boolean", "description": "Only visible elements (default: true)"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "browser_click",
                    "description": "Click an element using its ref from browser_snapshot (preferred) or a CSS selector.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "ref": {"type": "string", "description": "Element ref from snapshot (e.g., 'E5')"},
                        "selector": {"type": "string", "description": "CSS selector (fallback if ref not available)"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_type",
                    "description": "Type text into an input element. Use submit=true to press Enter after typing.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "ref": {"type": "string", "description": "Element ref from snapshot"},
                        "selector": {"type": "string", "description": "CSS selector (fallback)"},
                        "text": {"type": "string", "description": "Text to type"},
                        "clear": {"type": "boolean", "description": "Clear existing text first (default: true)"},
                        "submit": {"type": "boolean", "description": "Press Enter after typing (default: false)"}
                      },
                      "required": ["text"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_select",
                    "description": "Select option(s) in a dropdown by value or visible text.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "ref": {"type": "string", "description": "Element ref from snapshot"},
                        "selector": {"type": "string", "description": "CSS selector (fallback)"},
                        "values": {"type": "array", "items": {"type": "string"}, "description": "Values or text to select"}
                      },
                      "required": ["values"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_hover",
                    "description": "Hover over an element to reveal menus, tooltips, or trigger hover states.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "ref": {"type": "string", "description": "Element ref from snapshot"},
                        "selector": {"type": "string", "description": "CSS selector (fallback)"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_scroll",
                    "description": "Scroll the page by direction, to an element, or to coordinates. Use to load lazy content or find off-screen elements.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "direction": {"type": "string", "enum": ["up", "down", "left", "right"], "description": "Scroll direction"},
                        "ref": {"type": "string", "description": "Scroll to bring this element into view"},
                        "x": {"type": "number", "description": "X coordinate to scroll to"},
                        "y": {"type": "number", "description": "Y coordinate to scroll to"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "browser_press_key",
                    "description": "Press a keyboard key. Useful for Enter, Escape, Tab, arrow keys, or shortcuts.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "key": {"type": "string", "description": "Key name (Enter, Escape, Tab, ArrowUp, ArrowDown, etc.) or character"},
                        "modifiers": {"type": "array", "items": {"type": "string"}, "description": "Modifier keys: ctrl, shift, alt, meta/cmd"}
                      },
                      "required": ["key"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_wait_for",
                    "description": "Wait for text to appear, disappear, or for a specified time.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "text": {"type": "string", "description": "Wait for this text to appear"},
                        "text_gone": {"type": "string", "description": "Wait for this text to disappear"},
                        "time": {"type": "number", "description": "Wait for this many seconds"},
                        "timeout": {"type": "number", "description": "Max time to wait (default: 10s)"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "browser_screenshot",
                    "description": "Take a screenshot for visual debugging. Use full_page=true for entire page.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "path": {"type": "string", "description": "Save path (default: ~/Downloads/screenshot_<timestamp>.png)"},
                        "full_page": {"type": "boolean", "description": "Capture full scrollable page"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_execute_script",
                    "description": "Execute arbitrary JavaScript. Use as escape hatch for edge cases not covered by other tools.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "script": {"type": "string", "description": "JavaScript code to execute"}
                      },
                      "required": ["script"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  }
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
        case "browser_snapshot":
            return makeCString(ctx.snapshot(args: payload))
        case "browser_click":
            return makeCString(ctx.click(args: payload))
        case "browser_type":
            return makeCString(ctx.type(args: payload))
        case "browser_select":
            return makeCString(ctx.select(args: payload))
        case "browser_hover":
            return makeCString(ctx.hover(args: payload))
        case "browser_scroll":
            return makeCString(ctx.scroll(args: payload))
        case "browser_press_key":
            return makeCString(ctx.pressKey(args: payload))
        case "browser_wait_for":
            return makeCString(ctx.waitFor(args: payload))
        case "browser_screenshot":
            return makeCString(ctx.screenshot(args: payload))
        case "browser_execute_script":
            return makeCString(ctx.executeScript(args: payload))
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
