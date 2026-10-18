import Foundation

/// Model Context Protocol server over stdio (`Plumb --mcp`), so assistants like
/// Claude can read your focus data and drive the timer. Each tool forwards to a
/// command of the running app through the control socket.
struct MCPServer {
    static let protocolVersion = "2025-06-18"

    struct Tool {
        let name: String
        let command: String
        let description: String
        let properties: [String: [String: Any]]
        var required: [String] = []
        var readOnly = false
    }

    private static let task: [String: Any] = ["type": "string", "description": "Task title (or unique part of it), task id, or \"other\"."]

    static let tools: [Tool] = [
        Tool(name: "get_status", command: "status",
             description: "Current timer state: phase (work/shortBreak/longBreak), running/paused/idle, remaining seconds, selected task, today's completed intervals vs goal, streak, and whether the user is away.",
             properties: [:], readOnly: true),
        Tool(name: "start_timer", command: "start",
             description: "Start or resume the timer, optionally for a task. Starts whatever phase is next (work or break).",
             properties: ["task": task]),
        Tool(name: "pause_timer", command: "pause", description: "Pause the running timer.", properties: [:]),
        Tool(name: "skip_interval", command: "skip",
             description: "End the current interval early (kept in history as skipped) and move to the next phase.", properties: [:]),
        Tool(name: "stop_timer", command: "stop",
             description: "Abandon the current interval and reset to a fresh work interval. Work of at least a minute is kept as skipped.",
             properties: [:]),
        Tool(name: "extend_interval", command: "extend",
             description: "Add minutes to the running work interval. During a break: reopen the work interval that just ended, or end the break and work that many minutes.",
             properties: ["minutes": ["type": "integer", "minimum": 1, "maximum": 60]]),
        Tool(name: "list_tasks", command: "list_tasks",
             description: "List tasks with completed interval counts, estimates, due dates and work types.",
             properties: ["include_completed": ["type": "boolean", "default": false]], readOnly: true),
        Tool(name: "add_task", command: "add_task", description: "Create a task.",
             properties: [
                 "title": ["type": "string"],
                 "estimate": ["type": "integer", "description": "Estimated work intervals."],
                 "due": ["type": "string", "description": "Due date, YYYY-MM-DD."],
                 "work_type": ["type": "string", "description": "Name of an existing work type, e.g. \"50/10\"."],
                 "select": ["type": "boolean", "description": "Make it the timer's current task."],
             ], required: ["title"]),
        Tool(name: "complete_task", command: "complete_task", description: "Mark a task as completed.",
             properties: ["task": task], required: ["task"]),
        Tool(name: "select_task", command: "select_task", description: "Set the task the timer counts toward.",
             properties: ["task": task], required: ["task"]),
        Tool(name: "add_note", command: "add_note",
             description: "Attach a note (what got done) to a work interval; defaults to the one that just finished.",
             properties: ["note": ["type": "string"], "interval_id": ["type": "string"]], required: ["note"]),
        Tool(name: "add_interval", command: "add_interval",
             description: "Record a work interval that was not timed, e.g. focused work away from the Mac.",
             properties: [
                 "task": task,
                 "start": ["type": "string", "description": "Local start time, ISO 8601, e.g. 2026-10-18T09:30."],
                 "minutes": ["type": "number"],
                 "outcome": ["type": "string", "enum": ["completed", "skipped"]],
                 "note": ["type": "string"],
             ], required: ["start", "minutes"]),
        Tool(name: "get_report", command: "report",
             description: "Totals for a period: work hours, completed and skipped intervals, completed tasks, streak, hours by task, and how far estimates typically are off.",
             properties: ["period": ["type": "string",
                                     "enum": ReportPeriod.allCases.filter { $0 != .custom }.map(\.rawValue),
                                     "default": "this week"]], readOnly: true),
        Tool(name: "get_forecast", command: "forecast",
             description: "When a task will likely be done: remaining intervals and finish dates (10th/50th/90th percentile) from the user's real pace and estimate accuracy.",
             properties: ["task": task], required: ["task"], readOnly: true),
        Tool(name: "set_daily_goal", command: "set_goal", description: "Set today's goal in work intervals (1–30).",
             properties: ["goal": ["type": "integer", "minimum": 1, "maximum": 30]], required: ["goal"]),
    ]

    /// Executes a command; the socket in production, the command center in tests.
    let send: (String, [String: Any]) throws -> Any

    /// Handles one JSON-RPC message. Returns nil for notifications.
    func handle(_ message: [String: Any]) -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        let id = message["id"]
        guard id != nil else { return nil } // notification
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return reply(id, [
                "protocolVersion": requested ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "plumb", "title": "Plumb", "version": "1.0"],
                "instructions": "Plumb is the user's focus timer (work/break intervals). Use get_status before acting. Durations are in work intervals of the task's work type. Prefer get_report and get_forecast for questions about progress.",
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": Self.tools.map(describe)])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = Self.tools.first(where: { $0.name == name }) else {
                return error(id, -32602, "Unknown tool \(params["name"] ?? "")")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try send(tool.command, args)
                var payload: [String: Any] = ["content": [["type": "text", "text": Self.json(result)]], "isError": false]
                if let object = result as? [String: Any] { payload["structuredContent"] = object }
                return reply(id, payload)
            } catch {
                return reply(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return self.error(id, -32601, "Method not found: \(method)")
        }
    }

    private func describe(_ tool: Tool) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": tool.properties]
        if !tool.required.isEmpty { schema["required"] = tool.required }
        return [
            "name": tool.name, "description": tool.description, "inputSchema": schema,
            "annotations": ["readOnlyHint": tool.readOnly, "openWorldHint": false],
        ]
    }

    private func reply(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    /// Re-parsed JSON turns 28.9 into 28.899999999999999 on output; write
    /// floating-point numbers with their shortest exact form instead.
    static func clean(_ value: Any) -> Any {
        switch value {
        case let n as NSNumber where CFNumberIsFloatType(n) && !(n is NSDecimalNumber):
            return NSDecimalNumber(string: "\(n.doubleValue)")
        case let dict as [String: Any]:
            return dict.mapValues(clean)
        case let array as [Any]:
            return array.map(clean)
        default:
            return value
        }
    }

    static func json(_ value: Any) -> String {
        let value = clean(value)
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads newline-delimited JSON-RPC from stdin until EOF.
    static func runStdio() -> Never {
        let server = MCPServer { try ControlSocket.send($0, $1) }
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let response = server.handle(message),
               let out = try? JSONSerialization.data(withJSONObject: clean(response)) {
                FileHandle.standardOutput.write(out + Data([0x0A]))
            }
        }
        exit(0)
    }
}

/// `plumb <command> [...]`: the command line, through the control socket.
enum CLI {
    static let usage = """
    usage: plumb <command> [arguments] [--json]

      status                    show the timer
      start [task]              start or resume, optionally for a task
      pause | toggle | skip | stop
      extend [minutes]          add time to the current or just-finished interval
      tasks [--all]             list tasks
      add <title> [estimate]    create a task
      done <task>               complete a task
      select <task>             set the timer's task
      note <text>               note what you did in the last interval
      log <task> <start> <min>  record an untimed interval (start: 2026-10-18T09:30)
      report [period]           today, this week, last month, all time, ...
      forecast <task>           when a task will likely be done
      goal <n>                  set today's goal
    """

    static func run(_ args: [String]) -> Never {
        var words = args
        let asJSON = words.contains("--json")
        words.removeAll { $0 == "--json" }
        guard let verb = words.first else { print(usage); exit(0) }
        let rest = Array(words.dropFirst())
        let joined = rest.joined(separator: " ")
        let request: (String, [String: Any])
        switch verb {
        case "status": request = ("status", [:])
        case "start": request = ("start", joined.isEmpty ? [:] : ["task": joined])
        case "pause", "toggle", "skip", "stop": request = (verb, [:])
        case "extend": request = ("extend", rest.first.map { ["minutes": $0] } ?? [:])
        case "tasks": request = ("list_tasks", ["include_completed": rest.contains("--all")])
        case "add":
            if let last = rest.last, Int(last) != nil, rest.count > 1 {
                request = ("add_task", ["title": rest.dropLast().joined(separator: " "), "estimate": last])
            } else {
                request = ("add_task", ["title": joined])
            }
        case "done": request = ("complete_task", ["task": joined])
        case "select": request = ("select_task", ["task": joined])
        case "note": request = ("add_note", ["note": joined])
        case "log":
            guard rest.count >= 3 else { fail("usage: plumb log <task> <start> <minutes>") }
            request = ("add_interval", ["task": rest.dropLast(2).joined(separator: " "), "start": rest[rest.count - 2], "minutes": rest.last!])
        case "report": request = ("report", joined.isEmpty ? [:] : ["period": joined])
        case "forecast": request = ("forecast", ["task": joined])
        case "goal": request = ("set_goal", ["goal": joined])
        case "help", "-h", "--help": print(usage); exit(0)
        default: fail("unknown command “\(verb)”\n\n\(usage)")
        }
        do {
            let result = try ControlSocket.send(request.0, request.1)
            print(asJSON ? MCPServer.json(result) : format(request.0, result))
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    /// Compact human-readable output; everything else falls back to JSON.
    static func format(_ command: String, _ result: Any) -> String {
        if let s = result as? [String: Any], s["phase"] != nil, let remaining = s["remaining_seconds"] as? Int {
            let today = s["today"] as? [String: Any] ?? [:]
            var line = "\(s["phase"] ?? "") · \(s["status"] ?? "") · \(formatClock(TimeInterval(remaining))) · \(s["task"] ?? "")"
            line += " · today \(today["done"] ?? 0)/\(today["goal"] ?? 0)"
            if let streak = s["streak_days"] as? Int, streak > 0 { line += " · streak \(streak)" }
            if s["away_since"] != nil { line += " · paused while away" }
            return line
        }
        if command == "list_tasks", let tasks = result as? [[String: Any]] {
            return tasks.map { t in
                let done = t["completed_intervals"] ?? 0
                let count = t["estimate"].map { "\(done)/\($0)" } ?? "\(done)"
                return "\(t["completed"] as? Bool == true ? "✓" : "·") \(t["title"] ?? "")  \(count)"
            }.joined(separator: "\n")
        }
        return MCPServer.json(result)
    }
}
