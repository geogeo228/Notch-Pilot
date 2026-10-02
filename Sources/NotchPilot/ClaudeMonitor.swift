import Foundation
import Combine

enum ToolAction: String, Equatable {
    case none
    case reading    // Read, Grep, Glob, LS, NotebookRead
    case editing    // Edit, MultiEdit, Write, NotebookEdit
    case shell      // Bash (non-dangerous)
    case danger     // Bash with dangerous patterns (rm -rf, sudo rm, etc.)
    case thinking
    case web        // WebFetch, WebSearch
    case delegating // Task
    case planning   // TodoWrite
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    let projectName: String
    let projectPath: String
    let cwd: String
    let startTime: Date
    let lastActivity: Date
    let lastMessage: String
    let shortStatus: String
    let model: String
    let nativeMode: String   // Claude Code's own permission mode (from jsonl)
    let toolAction: ToolAction
    let isActive: Bool
    /// Approximate total prompt tokens used by the last turn — the
    /// current "context window size" as Claude sees it. Parsed from
    /// `message.usage.input_tokens + cache_read + cache_creation`.
    let contextTokens: Int
    /// Effective context window for this session: 200k by default,
    /// 1M if the session has been observed using > 190k at any
    /// point (meaning it's in Anthropic's 1M beta mode). Decided by
    /// the monitor via sticky caching — once bumped to 1M, stays 1M.
    let contextWindow: Int
    /// PID of the matched claude process — used by TerminalJumper to
    /// jump to the exact tmux pane when multiple sessions share a cwd.
    let claudePID: Int32?
}

@MainActor
final class ClaudeMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var processCount: Int = 0

    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Rebind weak self to a local let before the Task so the
            // inner concurrent closure isn't capturing a `var`. Swift 6's
            // strict concurrency rejects the var capture across actors.
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // Georgi fork: scanning runs on a background actor; the main thread
    // only publishes the result.
    private let scanner = ClaudeScanner()
    private var scanInFlight = false

    private func refresh() {
        // Skip if the previous pass is still running (slow disk) — no
        // pile-up of tasks.
        guard !scanInFlight else { return }
        scanInFlight = true
        Task { @MainActor in
            let result = await scanner.scan()
            if result.sessions != sessions { sessions = result.sessions }
            if result.processCount != processCount { processCount = result.processCount }
            scanInFlight = false
        }
    }

    // MARK: - Session detail timeline

    /// Loads a chronological tail of events from a given session's jsonl.
    /// Used by the session-detail overlay. Returns oldest → newest.
    func recentEvents(for session: ClaudeSession, limit: Int = 30) -> [SessionEvent] {
        let url = URL(fileURLWithPath: session.projectPath)
            .appendingPathComponent("\(session.id).jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        // Read a generous tail — 256KB is enough for 30+ entries on
        // typical sessions and still cheap.
        let tail = ClaudeScanner.readTail(url, bytes: 256 * 1024)
        guard !tail.isEmpty else { return [] }

        let lines = tail.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        var events: [SessionEvent] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String ?? ""
            let tsString = obj["timestamp"] as? String ?? ""
            let ts = Self.parseTimestamp(tsString) ?? Date()

            switch type {
            case "user":
                if let msg = obj["message"] as? [String: Any] {
                    // Tool result arrives as a user-typed entry with a
                    // tool_result content block — don't mistake for a
                    // real user prompt.
                    if let blocks = msg["content"] as? [[String: Any]],
                       let block = blocks.first(where: { ($0["type"] as? String) == "tool_result" }) {
                        let isError = (block["is_error"] as? Bool) ?? false
                        let body = Self.toolResultText(from: block)
                        events.append(SessionEvent(
                            kind: .toolResult,
                            timestamp: ts,
                            label: isError ? "Error" : "Result",
                            body: body,
                            icon: isError ? "exclamationmark.triangle" : "checkmark.circle",
                            isError: isError
                        ))
                    } else if let text = msg["content"] as? String, !text.isEmpty {
                        events.append(SessionEvent(
                            kind: .user,
                            timestamp: ts,
                            label: "You",
                            body: String(text.prefix(400)),
                            icon: "person.fill",
                            isError: false
                        ))
                    } else if let blocks = msg["content"] as? [[String: Any]],
                              let first = blocks.first(where: { ($0["type"] as? String) == "text" }),
                              let text = first["text"] as? String {
                        events.append(SessionEvent(
                            kind: .user,
                            timestamp: ts,
                            label: "You",
                            body: String(text.prefix(400)),
                            icon: "person.fill",
                            isError: false
                        ))
                    }
                }

            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let content = msg["content"] as? [[String: Any]]
                else { continue }

                for block in content {
                    let bt = block["type"] as? String ?? ""
                    switch bt {
                    case "tool_use":
                        let name = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        events.append(SessionEvent(
                            kind: .toolUse,
                            timestamp: ts,
                            label: name,
                            body: Self.toolUseSummary(name: name, input: input),
                            icon: Self.toolIcon(for: name),
                            isError: false
                        ))
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            events.append(SessionEvent(
                                kind: .assistantText,
                                timestamp: ts,
                                label: "Claude",
                                body: String(text.prefix(400)),
                                icon: "sparkles",
                                isError: false
                            ))
                        }
                    case "thinking":
                        events.append(SessionEvent(
                            kind: .thinking,
                            timestamp: ts,
                            label: "Thinking",
                            body: "",
                            icon: "brain",
                            isError: false
                        ))
                    default:
                        continue
                    }
                }

            default:
                continue
            }
        }

        // Newest last. Trim to the limit.
        if events.count > limit {
            return Array(events.suffix(limit))
        }
        return events
    }

    private static func toolResultText(from block: [String: Any]) -> String {
        if let s = block["content"] as? String {
            return String(s.prefix(300))
        }
        if let arr = block["content"] as? [[String: Any]] {
            let combined = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return String(combined.prefix(300))
        }
        return ""
    }

    private static func toolUseSummary(name: String, input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return String(cmd.prefix(220)) }
        if let path = input["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        if let pattern = input["pattern"] as? String { return pattern }
        if let url = input["url"] as? String { return url }
        if let query = input["query"] as? String { return query }
        if let questions = input["questions"] as? [[String: Any]],
           let first = questions.first,
           let q = first["question"] as? String {
            return String(q.prefix(220))
        }
        return ""
    }

    private static func toolIcon(for name: String) -> String {
        switch name.lowercased() {
        case "bash", "bashoutput", "killshell": return "terminal"
        case "read", "notebookread":            return "doc.text"
        case "write":                            return "doc.badge.plus"
        case "edit", "multiedit", "notebookedit": return "pencil.and.outline"
        case "grep":                             return "magnifyingglass"
        case "glob", "ls":                       return "folder"
        case "webfetch":                         return "arrow.down.circle"
        case "websearch":                        return "globe"
        case "task":                             return "square.stack.3d.up"
        case "todowrite":                        return "checklist"
        case "askuserquestion":                  return "questionmark.bubble"
        default:                                 return "wrench.and.screwdriver"
        }
    }

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let timestampFormatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ s: String) -> Date? {
        timestampFormatter.date(from: s) ?? timestampFormatterPlain.date(from: s)
    }
}

/// One entry in a session's timeline as shown in the session-detail overlay.
struct SessionEvent: Identifiable {
    enum Kind {
        case user
        case assistantText
        case toolUse
        case thinking
        case toolResult
    }

    let id = UUID()
    let kind: Kind
    let timestamp: Date
    let label: String
    let body: String
    let icon: String
    let isError: Bool
}
