import Foundation

// MARK: - Helpers

private func escapeJSON(_ s: String) -> String {
    return
        s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

private func resolvePath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return expanded
    }
    return FileManager.default.currentDirectoryPath + "/" + expanded
}

private func formatDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func fileTypeString(_ fileType: FileAttributeType?) -> String {
    guard let fileType = fileType else { return "unknown" }
    switch fileType {
    case .typeRegular: return "file"
    case .typeDirectory: return "directory"
    case .typeSymbolicLink: return "symlink"
    case .typeSocket: return "socket"
    case .typeBlockSpecial: return "block"
    case .typeCharacterSpecial: return "character"
    default: return "unknown"
    }
}

private func matchesGlobPattern(_ name: String, pattern: String) -> Bool {
    // Convert glob pattern to regex
    var regexPattern = "^"
    for char in pattern {
        switch char {
        case "*":
            regexPattern += ".*"
        case "?":
            regexPattern += "."
        case ".":
            regexPattern += "\\."
        case "[", "]", "(", ")", "{", "}", "^", "$", "+", "|", "\\":
            regexPattern += "\\\(char)"
        default:
            regexPattern += String(char)
        }
    }
    regexPattern += "$"

    guard let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive) else {
        return name.contains(pattern.replacingOccurrences(of: "*", with: ""))
    }

    let range = NSRange(name.startIndex..., in: name)
    return regex.firstMatch(in: name, range: range) != nil
}

// MARK: - Tool Implementations

private struct ReadFileTool {
    let name = "read_file"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String
            let encoding: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: path\"}"
        }

        let fullPath = resolvePath(input.path)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: fullPath) else {
            return "{\"error\": \"File not found: \(escapeJSON(fullPath))\"}"
        }

        guard fileManager.isReadableFile(atPath: fullPath) else {
            return "{\"error\": \"File is not readable: \(escapeJSON(fullPath))\"}"
        }

        do {
            let fileData = try Data(contentsOf: URL(fileURLWithPath: fullPath))
            let encoding = input.encoding ?? "utf8"

            if encoding == "base64" {
                let base64 = fileData.base64EncodedString()
                return "{\"content\": \"\(base64)\", \"encoding\": \"base64\", \"size\": \(fileData.count)}"
            } else {
                if let content = String(data: fileData, encoding: .utf8) {
                    return
                        "{\"content\": \"\(escapeJSON(content))\", \"encoding\": \"utf8\", \"size\": \(fileData.count)}"
                } else {
                    // Fall back to base64 for binary files
                    let base64 = fileData.base64EncodedString()
                    return
                        "{\"content\": \"\(base64)\", \"encoding\": \"base64\", \"size\": \(fileData.count), \"note\": \"File contains binary data, returned as base64\"}"
                }
            }
        } catch {
            return "{\"error\": \"Failed to read file: \(escapeJSON(error.localizedDescription))\"}"
        }
    }
}

private struct WriteFileTool {
    let name = "write_file"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String
            let content: String
            let create_dirs: Bool?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: path, content\"}"
        }

        let fullPath = resolvePath(input.path)
        let fileManager = FileManager.default
        let fileURL = URL(fileURLWithPath: fullPath)

        // Create parent directories if requested
        if input.create_dirs == true {
            let parentDir = fileURL.deletingLastPathComponent().path
            if !fileManager.fileExists(atPath: parentDir) {
                do {
                    try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                } catch {
                    return
                        "{\"error\": \"Failed to create parent directories: \(escapeJSON(error.localizedDescription))\"}"
                }
            }
        }

        do {
            try input.content.write(to: fileURL, atomically: true, encoding: .utf8)
            let attrs = try fileManager.attributesOfItem(atPath: fullPath)
            let size = attrs[.size] as? Int64 ?? 0
            return "{\"success\": true, \"path\": \"\(escapeJSON(fullPath))\", \"size\": \(size)}"
        } catch {
            return "{\"error\": \"Failed to write file: \(escapeJSON(error.localizedDescription))\"}"
        }
    }
}

private struct ListDirectoryTool {
    let name = "list_directory"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String
            let recursive: Bool?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: path\"}"
        }

        let fullPath = resolvePath(input.path)
        let fileManager = FileManager.default
        let recursive = input.recursive ?? false

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return "{\"error\": \"Directory not found: \(escapeJSON(fullPath))\"}"
        }

        do {
            let entries: [String]
            if recursive {
                entries = try fileManager.subpathsOfDirectory(atPath: fullPath)
            } else {
                entries = try fileManager.contentsOfDirectory(atPath: fullPath)
            }

            var items: [String] = []
            for entry in entries {
                let entryPath = fullPath + "/" + entry
                if let attrs = try? fileManager.attributesOfItem(atPath: entryPath) {
                    let fileType = attrs[.type] as? FileAttributeType
                    let size = attrs[.size] as? Int64 ?? 0
                    let modified = attrs[.modificationDate] as? Date
                    let modifiedStr = modified.map { formatDate($0) } ?? ""

                    items.append(
                        "{\"name\": \"\(escapeJSON(entry))\", \"type\": \"\(fileTypeString(fileType))\", \"size\": \(size), \"modified\": \"\(modifiedStr)\"}"
                    )
                }
            }

            return "{\"path\": \"\(escapeJSON(fullPath))\", \"entries\": [\(items.joined(separator: ", "))]}"
        } catch {
            return "{\"error\": \"Failed to list directory: \(escapeJSON(error.localizedDescription))\"}"
        }
    }
}

private struct CreateDirectoryTool {
    let name = "create_directory"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String
            let recursive: Bool?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: path\"}"
        }

        let fullPath = resolvePath(input.path)
        let fileManager = FileManager.default
        let recursive = input.recursive ?? true

        do {
            try fileManager.createDirectory(atPath: fullPath, withIntermediateDirectories: recursive)
            return "{\"success\": true, \"path\": \"\(escapeJSON(fullPath))\"}"
        } catch {
            return "{\"error\": \"Failed to create directory: \(escapeJSON(error.localizedDescription))\"}"
        }
    }
}

private struct DeleteFileTool {
    let name = "delete_file"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String
            let recursive: Bool?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: path\"}"
        }

        let fullPath = resolvePath(input.path)
        let fileManager = FileManager.default
        let recursive = input.recursive ?? false

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
            return "{\"error\": \"Path not found: \(escapeJSON(fullPath))\"}"
        }

        // If it's a directory and not recursive, check if it's empty
        if isDirectory.boolValue && !recursive {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: fullPath)
                if !contents.isEmpty {
                    return
                        "{\"error\": \"Directory is not empty. Use recursive: true to delete non-empty directories.\"}"
                }
            } catch {
                return "{\"error\": \"Failed to check directory contents: \(escapeJSON(error.localizedDescription))\"}"
            }
        }

        do {
            try fileManager.removeItem(atPath: fullPath)
            return "{\"success\": true, \"path\": \"\(escapeJSON(fullPath))\"}"
        } catch {
            return "{\"error\": \"Failed to delete: \(escapeJSON(error.localizedDescription))\"}"
        }
    }
}

private struct MoveFileTool {
    let name = "move_file"

    func run(args: String) -> String {
        struct Args: Decodable {
            let source: String
            let destination: String
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: source, destination\"}"
        }

        let sourcePath = resolvePath(input.source)
        let destPath = resolvePath(input.destination)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sourcePath) else {
            return "{\"error\": \"Source not found: \(escapeJSON(sourcePath))\"}"
        }

        do {
            try fileManager.moveItem(atPath: sourcePath, toPath: destPath)
            return
                "{\"success\": true, \"source\": \"\(escapeJSON(sourcePath))\", \"destination\": \"\(escapeJSON(destPath))\"}"
        } catch {
            return "{\"error\": \"Failed to move: \(escapeJSON(error.localizedDescription))\"}"
        }
    }
}

private struct SearchFilesTool {
    let name = "search_files"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String
            let pattern: String
            let recursive: Bool?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: path, pattern\"}"
        }

        let fullPath = resolvePath(input.path)
        let fileManager = FileManager.default
        let recursive = input.recursive ?? true

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return "{\"error\": \"Directory not found: \(escapeJSON(fullPath))\"}"
        }

        do {
            let entries: [String]
            if recursive {
                entries = try fileManager.subpathsOfDirectory(atPath: fullPath)
            } else {
                entries = try fileManager.contentsOfDirectory(atPath: fullPath)
            }

            var matches: [String] = []
            for entry in entries {
                let fileName = (entry as NSString).lastPathComponent
                if matchesGlobPattern(fileName, pattern: input.pattern) {
                    let entryPath = fullPath + "/" + entry
                    if let attrs = try? fileManager.attributesOfItem(atPath: entryPath) {
                        let fileType = attrs[.type] as? FileAttributeType
                        let size = attrs[.size] as? Int64 ?? 0
                        matches.append(
                            "{\"path\": \"\(escapeJSON(entry))\", \"type\": \"\(fileTypeString(fileType))\", \"size\": \(size)}"
                        )
                    }
                }
            }

            return
                "{\"search_path\": \"\(escapeJSON(fullPath))\", \"pattern\": \"\(escapeJSON(input.pattern))\", \"matches\": [\(matches.joined(separator: ", "))], \"count\": \(matches.count)}"
        } catch {
            return "{\"error\": \"Failed to search: \(escapeJSON(error.localizedDescription))\"}"
        }
    }
}

private struct GetFileInfoTool {
    let name = "get_file_info"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: path\"}"
        }

        let fullPath = resolvePath(input.path)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: fullPath) else {
            return "{\"error\": \"Path not found: \(escapeJSON(fullPath))\"}"
        }

        do {
            let attrs = try fileManager.attributesOfItem(atPath: fullPath)

            let fileType = attrs[.type] as? FileAttributeType
            let size = attrs[.size] as? Int64 ?? 0
            let created = attrs[.creationDate] as? Date
            let modified = attrs[.modificationDate] as? Date
            let permissions = attrs[.posixPermissions] as? Int ?? 0
            let owner = attrs[.ownerAccountName] as? String ?? ""
            let group = attrs[.groupOwnerAccountName] as? String ?? ""

            let createdStr = created.map { formatDate($0) } ?? ""
            let modifiedStr = modified.map { formatDate($0) } ?? ""
            let permissionsStr = String(format: "%o", permissions)

            let isReadable = fileManager.isReadableFile(atPath: fullPath)
            let isWritable = fileManager.isWritableFile(atPath: fullPath)
            let isExecutable = fileManager.isExecutableFile(atPath: fullPath)

            return """
                {"path": "\(escapeJSON(fullPath))", "type": "\(fileTypeString(fileType))", "size": \(size), "created": "\(createdStr)", "modified": "\(modifiedStr)", "permissions": "\(permissionsStr)", "owner": "\(escapeJSON(owner))", "group": "\(escapeJSON(group))", "readable": \(isReadable), "writable": \(isWritable), "executable": \(isExecutable)}
                """
        } catch {
            return "{\"error\": \"Failed to get file info: \(escapeJSON(error.localizedDescription))\"}"
        }
    }
}

// MARK: - Plugin Context

private class PluginContext {
    let readFileTool = ReadFileTool()
    let writeFileTool = WriteFileTool()
    let listDirectoryTool = ListDirectoryTool()
    let createDirectoryTool = CreateDirectoryTool()
    let deleteFileTool = DeleteFileTool()
    let moveFileTool = MoveFileTool()
    let searchFilesTool = SearchFilesTool()
    let getFileInfoTool = GetFileInfoTool()
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
              "plugin_id": "osaurus.filesystem",
              "version": "1.0.0",
              "description": "Secure file system operations for reading, writing, and managing files and directories",
              "capabilities": {
                "tools": [
                  {"id": "read_file", "description": "Read the contents of a file", "parameters": {"type":"object","properties":{"path":{"type":"string"},"encoding":{"type":"string"}},"required":["path"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "write_file", "description": "Write content to a file", "parameters": {"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"create_dirs":{"type":"boolean"}},"required":["path","content"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "list_directory", "description": "List directory contents", "parameters": {"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"}},"required":["path"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "create_directory", "description": "Create a directory", "parameters": {"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"}},"required":["path"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "delete_file", "description": "Delete a file or directory", "parameters": {"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"}},"required":["path"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "move_file", "description": "Move or rename a file or directory", "parameters": {"type":"object","properties":{"source":{"type":"string"},"destination":{"type":"string"}},"required":["source","destination"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "search_files", "description": "Search for files by glob pattern", "parameters": {"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"recursive":{"type":"boolean"}},"required":["path","pattern"]}, "requirements": [], "permission_policy": "ask"},
                  {"id": "get_file_info", "description": "Get file metadata", "parameters": {"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}, "requirements": [], "permission_policy": "ask"}
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
        case ctx.readFileTool.name:
            return makeCString(ctx.readFileTool.run(args: payload))
        case ctx.writeFileTool.name:
            return makeCString(ctx.writeFileTool.run(args: payload))
        case ctx.listDirectoryTool.name:
            return makeCString(ctx.listDirectoryTool.run(args: payload))
        case ctx.createDirectoryTool.name:
            return makeCString(ctx.createDirectoryTool.run(args: payload))
        case ctx.deleteFileTool.name:
            return makeCString(ctx.deleteFileTool.run(args: payload))
        case ctx.moveFileTool.name:
            return makeCString(ctx.moveFileTool.run(args: payload))
        case ctx.searchFilesTool.name:
            return makeCString(ctx.searchFilesTool.run(args: payload))
        case ctx.getFileInfoTool.name:
            return makeCString(ctx.getFileInfoTool.run(args: payload))
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
