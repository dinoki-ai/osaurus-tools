import Foundation

// MARK: - Shell Execution Helper

private func runGit(_ arguments: [String], in directory: String?) -> (output: String, error: String, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments

    if let dir = directory {
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
    }

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ("", "Failed to execute git: \(error.localizedDescription)", 1)
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    let output = String(data: outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

    return (
        output.trimmingCharacters(in: .whitespacesAndNewlines),
        errorOutput.trimmingCharacters(in: .whitespacesAndNewlines),
        process.terminationStatus
    )
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

// MARK: - Tool Implementations

private struct GitStatusTool {
    let name = "git_status"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(path: nil)
        }

        let result = runGit(["status", "--porcelain", "-b"], in: input.path)

        if result.exitCode != 0 {
            return "{\"error\": \"\(escapeJSON(result.error))\"}"
        }

        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false)
        var branch = ""
        var staged: [String] = []
        var unstaged: [String] = []
        var untracked: [String] = []

        for line in lines {
            let lineStr = String(line)
            if lineStr.hasPrefix("## ") {
                // Parse branch info
                let branchPart = lineStr.dropFirst(3)
                if let dots = branchPart.range(of: "...") {
                    branch = String(branchPart[..<dots.lowerBound])
                } else {
                    branch = String(branchPart.split(separator: " ").first ?? "")
                }
            } else if lineStr.count >= 2 {
                let index = lineStr.index(lineStr.startIndex, offsetBy: 0)
                let worktree = lineStr.index(lineStr.startIndex, offsetBy: 1)
                let file = String(lineStr.dropFirst(3))

                let indexStatus = lineStr[index]
                let worktreeStatus = lineStr[worktree]

                if indexStatus == "?" {
                    untracked.append(file)
                } else {
                    if indexStatus != " " {
                        staged.append(file)
                    }
                    if worktreeStatus != " " && worktreeStatus != "?" {
                        unstaged.append(file)
                    }
                }
            }
        }

        let stagedJson = staged.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",")
        let unstagedJson = unstaged.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",")
        let untrackedJson = untracked.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",")

        return """
            {"branch": "\(escapeJSON(branch))", "staged": [\(stagedJson)], "unstaged": [\(unstagedJson)], "untracked": [\(untrackedJson)]}
            """
    }
}

private struct GitLogTool {
    let name = "git_log"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String?
            let limit: Int?
            let branch: String?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(path: nil, limit: nil, branch: nil)
        }

        let limit = input.limit ?? 10
        var gitArgs = ["log", "--format=%H|%an|%ae|%at|%s", "-n", "\(limit)"]
        if let branch = input.branch {
            gitArgs.append(branch)
        }

        let result = runGit(gitArgs, in: input.path)

        if result.exitCode != 0 {
            return "{\"error\": \"\(escapeJSON(result.error))\"}"
        }

        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true)
        var commits: [String] = []

        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            if parts.count >= 5 {
                let hash = String(parts[0])
                let author = String(parts[1])
                let email = String(parts[2])
                let timestamp = String(parts[3])
                let message = String(parts[4])

                commits.append(
                    """
                    {"hash": "\(escapeJSON(hash))", "author": "\(escapeJSON(author))", "email": "\(escapeJSON(email))", "timestamp": \(timestamp), "message": "\(escapeJSON(message))"}
                    """)
            }
        }

        return "{\"commits\": [\(commits.joined(separator: ","))]}"
    }
}

private struct GitDiffTool {
    let name = "git_diff"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String?
            let ref1: String?
            let ref2: String?
            let file: String?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(path: nil, ref1: nil, ref2: nil, file: nil)
        }

        var gitArgs = ["diff"]

        if let ref1 = input.ref1 {
            gitArgs.append(ref1)
            if let ref2 = input.ref2 {
                gitArgs.append(ref2)
            }
        }

        gitArgs.append("--")

        if let file = input.file {
            gitArgs.append(file)
        }

        let result = runGit(gitArgs, in: input.path)

        if result.exitCode != 0 {
            return "{\"error\": \"\(escapeJSON(result.error))\"}"
        }

        // Also get stats
        var statsArgs = ["diff", "--stat"]
        if let ref1 = input.ref1 {
            statsArgs.append(ref1)
            if let ref2 = input.ref2 {
                statsArgs.append(ref2)
            }
        }
        statsArgs.append("--")
        if let file = input.file {
            statsArgs.append(file)
        }

        let statsResult = runGit(statsArgs, in: input.path)

        return """
            {"diff": "\(escapeJSON(result.output))", "stats": "\(escapeJSON(statsResult.output))"}
            """
    }
}

private struct GitBranchTool {
    let name = "git_branch"

    func run(args: String) -> String {
        struct Args: Decodable {
            let path: String?
            let list_all: Bool?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(path: nil, list_all: nil)
        }

        let listAll = input.list_all ?? false

        // Get current branch
        let currentResult = runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: input.path)
        if currentResult.exitCode != 0 {
            return "{\"error\": \"\(escapeJSON(currentResult.error))\"}"
        }
        let currentBranch = currentResult.output

        if !listAll {
            return "{\"current\": \"\(escapeJSON(currentBranch))\"}"
        }

        // List all branches
        let branchResult = runGit(["branch", "-a", "--format=%(refname:short)"], in: input.path)
        if branchResult.exitCode != 0 {
            return "{\"error\": \"\(escapeJSON(branchResult.error))\"}"
        }

        let branches = branchResult.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { "\"\(escapeJSON(String($0)))\"" }
            .joined(separator: ",")

        return "{\"current\": \"\(escapeJSON(currentBranch))\", \"branches\": [\(branches)]}"
    }
}

// MARK: - Plugin Context

private class PluginContext {
    let gitStatusTool = GitStatusTool()
    let gitLogTool = GitLogTool()
    let gitDiffTool = GitDiffTool()
    let gitBranchTool = GitBranchTool()
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
              "plugin_id": "osaurus.git",
              "version": "1.0.0",
              "description": "Git repository utilities for Osaurus",
              "capabilities": {
                "tools": [
                  {
                    "id": "git_status",
                    "description": "Get the current status of a git repository including staged, unstaged, and untracked files",
                    "parameters": {"type":"object","properties":{"path":{"type":"string","description":"Path to the git repository. Defaults to current working directory."}},"required":[]},
                    "requirements": ["git"],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "git_log",
                    "description": "Get the commit history of a git repository",
                    "parameters": {"type":"object","properties":{"path":{"type":"string","description":"Path to the git repository. Defaults to current working directory."},"limit":{"type":"number","description":"Maximum number of commits to return. Defaults to 10."},"branch":{"type":"string","description":"Branch name to get history from. Defaults to current branch."}},"required":[]},
                    "requirements": ["git"],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "git_diff",
                    "description": "Show changes between commits, commit and working tree, etc.",
                    "parameters": {"type":"object","properties":{"path":{"type":"string","description":"Path to the git repository. Defaults to current working directory."},"ref1":{"type":"string","description":"First reference (commit, branch, tag). Defaults to HEAD."},"ref2":{"type":"string","description":"Second reference. If not provided, shows diff against working directory."},"file":{"type":"string","description":"Specific file to diff. If not provided, shows all changes."}},"required":[]},
                    "requirements": ["git"],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "git_branch",
                    "description": "List branches or get the current branch name",
                    "parameters": {"type":"object","properties":{"path":{"type":"string","description":"Path to the git repository. Defaults to current working directory."},"list_all":{"type":"boolean","description":"If true, list all branches. If false, return only current branch. Defaults to false."}},"required":[]},
                    "requirements": ["git"],
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
        case ctx.gitStatusTool.name:
            return makeCString(ctx.gitStatusTool.run(args: payload))
        case ctx.gitLogTool.name:
            return makeCString(ctx.gitLogTool.run(args: payload))
        case ctx.gitDiffTool.name:
            return makeCString(ctx.gitDiffTool.run(args: payload))
        case ctx.gitBranchTool.name:
            return makeCString(ctx.gitBranchTool.run(args: payload))
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
