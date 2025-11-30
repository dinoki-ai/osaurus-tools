import Foundation

// MARK: - Tool Implementations

private struct CurrentTimeTool {
    let name = "current_time"

    func run(args: String) -> String {
        struct Args: Decodable {
            let timezone: String?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(timezone: nil)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var timeZone = TimeZone.current
        if let tz = input.timezone, let parsedTZ = TimeZone(identifier: tz) {
            timeZone = parsedTZ
        }
        formatter.timeZone = timeZone

        let now = Date()
        let iso = formatter.string(from: now)
        let unix = now.timeIntervalSince1970

        return """
            {"datetime": "\(iso)", "unix_timestamp": \(unix), "timezone": "\(timeZone.identifier)"}
            """
    }
}

private struct FormatDateTool {
    let name = "format_date"

    func run(args: String) -> String {
        struct Args: Decodable {
            let timestamp: Double?
            let format: String?
            let timezone: String?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(timestamp: nil, format: nil, timezone: nil)
        }

        let date: Date
        if let ts = input.timestamp {
            date = Date(timeIntervalSince1970: ts)
        } else {
            date = Date()
        }

        var timeZone = TimeZone.current
        if let tz = input.timezone, let parsedTZ = TimeZone(identifier: tz) {
            timeZone = parsedTZ
        }

        let format = input.format ?? "iso8601"
        let formatted: String

        switch format.lowercased() {
        case "iso8601":
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = timeZone
            formatted = formatter.string(from: date)

        case "rfc2822":
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatted = formatter.string(from: date)

        case "relative":
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            formatted = formatter.localizedString(for: date, relativeTo: Date())

        default:
            // Treat as strftime-style format
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = timeZone
            formatted = formatter.string(from: date)
        }

        return """
            {"formatted": "\(formatted)", "format": "\(format)", "timezone": "\(timeZone.identifier)"}
            """
    }
}

// MARK: - Plugin Context

private class PluginContext {
    let currentTimeTool = CurrentTimeTool()
    let formatDateTool = FormatDateTool()
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
              "plugin_id": "osaurus.time",
              "version": "1.0.0",
              "description": "Time and date utilities for Osaurus",
              "capabilities": {
                "tools": [
                  {
                    "id": "current_time",
                    "description": "Get the current date and time, optionally in a specific timezone",
                    "parameters": {"type":"object","properties":{"timezone":{"type":"string","description":"IANA timezone identifier (e.g., 'America/New_York', 'UTC'). Defaults to system timezone."}},"required":[]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "format_date",
                    "description": "Format a timestamp or date string into a specified format",
                    "parameters": {"type":"object","properties":{"timestamp":{"type":"number","description":"Unix timestamp in seconds. If not provided, uses current time."},"format":{"type":"string","description":"Output format: 'iso8601', 'rfc2822', 'relative', or a custom strftime format string. Defaults to 'iso8601'."},"timezone":{"type":"string","description":"IANA timezone identifier for output. Defaults to system timezone."}},"required":[]},
                    "requirements": [],
                    "permission_policy": "allow"
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
        case ctx.currentTimeTool.name:
            return makeCString(ctx.currentTimeTool.run(args: payload))
        case ctx.formatDateTool.name:
            return makeCString(ctx.formatDateTool.run(args: payload))
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
