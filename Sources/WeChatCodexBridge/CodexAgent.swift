import Foundation

public enum CodexSandbox: String, CaseIterable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    fileprivate func policy(workspace: URL) -> JSONValue {
        switch self {
        case .readOnly:
            .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(false),
            ])
        case .workspaceWrite:
            .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array([.string(workspace.path)]),
                "networkAccess": .bool(false),
            ])
        case .dangerFullAccess:
            .object(["type": .string("dangerFullAccess")])
        }
    }
}

public struct CodexAgentConfiguration: Sendable {
    public let workspace: URL
    public let model: String?
    public let reasoningEffort: String?
    public let sandbox: CodexSandbox

    public init(
        workspace: URL,
        model: String? = nil,
        reasoningEffort: String? = nil,
        sandbox: CodexSandbox = .workspaceWrite
    ) {
        self.workspace = workspace.standardizedFileURL
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.sandbox = sandbox
    }
}

public struct CodexAgentResult: Sendable {
    public let threadID: String
    public let text: String
}

public enum CodexRequestBuilder {
    public static func threadStart(
        configuration: CodexAgentConfiguration
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(configuration.workspace.path),
            "approvalPolicy": .string("never"),
            "sandbox": .string(configuration.sandbox.rawValue),
            "serviceName": .string("wechat_codex_bridge"),
            "serviceTier": .null,
        ]
        if let model = configuration.model { params["model"] = .string(model) }
        return .object(params)
    }

    public static func threadResume(
        threadID: String,
        configuration: CodexAgentConfiguration
    ) -> JSONValue {
        .object([
            "threadId": .string(threadID),
            "cwd": .string(configuration.workspace.path),
            "approvalPolicy": .string("never"),
        ])
    }

    public static func turnStart(
        threadID: String,
        text: String,
        configuration: CodexAgentConfiguration
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ]),
            ]),
            "cwd": .string(configuration.workspace.path),
            "approvalPolicy": .string("never"),
            "sandboxPolicy": configuration.sandbox.policy(
                workspace: configuration.workspace
            ),
            "serviceTier": .null,
        ]
        if let model = configuration.model { params["model"] = .string(model) }
        if let effort = configuration.reasoningEffort {
            params["effort"] = .string(effort)
        }
        return .object(params)
    }
}

public enum CodexAgentError: LocalizedError, Sendable {
    case invalidResponse
    case turnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Codex 返回的数据缺少 thread 或 turn"
        case .turnFailed(let detail): detail.isEmpty ? "Codex 任务执行失败" : detail
        }
    }
}

public actor CodexAgent {
    private let client: CodexAppServer
    private let configuration: CodexAgentConfiguration
    private var eventTask: Task<Void, Never>?
    private var completedTurns: [String: Result<Void, CodexAgentError>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Error>] = [:]

    public init(client: CodexAppServer, configuration: CodexAgentConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    deinit { eventTask?.cancel() }

    public func run(text: String, preferredThreadID: String?) async throws -> CodexAgentResult {
        observeEventsIfNeeded()
        let threadID = try await resolveThread(preferredThreadID)
        let response = try await client.request(
            method: "turn/start",
            params: CodexRequestBuilder.turnStart(
                threadID: threadID,
                text: text,
                configuration: configuration
            )
        )
        guard let turnID = response["turn"]?["id"]?.stringValue else {
            throw CodexAgentError.invalidResponse
        }
        if response["turn"]?["status"]?.stringValue == "inProgress" {
            let reconciliation = Task { [weak self] in
                await self?.reconcileCompletion(
                    threadID: threadID,
                    turnID: turnID
                )
            }
            defer { reconciliation.cancel() }
            try await waitForTurn(turnID)
        }
        let read = try await client.request(
            method: "thread/read",
            params: .object([
                "threadId": .string(threadID),
                "includeTurns": .bool(true),
            ])
        )
        guard let thread = read["thread"] else { throw CodexAgentError.invalidResponse }
        let turns = thread["turns"]?.arrayValue ?? []
        guard let turn = turns.last(where: { $0["id"]?.stringValue == turnID }) else {
            throw CodexAgentError.invalidResponse
        }
        let output = (turn["items"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "agentMessage" }
            .compactMap { $0["text"]?.stringValue }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return CodexAgentResult(threadID: threadID, text: output)
    }

    public func stop() async { await client.stop() }

    private func observeEventsIfNeeded() {
        guard eventTask == nil else { return }
        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    private func resolveThread(_ preferred: String?) async throws -> String {
        if let preferred, !preferred.isEmpty {
            do {
                _ = try await client.request(
                    method: "thread/resume",
                    params: CodexRequestBuilder.threadResume(
                        threadID: preferred,
                        configuration: configuration
                    )
                )
                return preferred
            } catch {
                // Resuming has not started a turn, so creating a fresh thread
                // cannot repeat user work. This also heals a removed/stale ID.
            }
        }
        let response = try await client.request(
            method: "thread/start",
            params: CodexRequestBuilder.threadStart(
                configuration: configuration
            )
        )
        guard let threadID = response["thread"]?["id"]?.stringValue else {
            throw CodexAgentError.invalidResponse
        }
        return threadID
    }

    private func waitForTurn(_ turnID: String) async throws {
        if let result = completedTurns.removeValue(forKey: turnID) {
            return try result.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters[turnID] = continuation
        }
    }

    private func handle(_ event: CodexServerEvent) async {
        switch event {
        case .notification(let method, let params):
            guard method == "turn/completed",
                  let turnID = params["turn"]?["id"]?.stringValue
            else { return }
            let status = params["turn"]?["status"]?.stringValue
            let result: Result<Void, CodexAgentError>
            if status == "failed" || status == "interrupted" || status == "cancelled" {
                result = .failure(
                    .turnFailed(
                        params["turn"]?["error"]?["message"]?.stringValue
                            ?? "Codex 任务未完成（\(status ?? "unknown")）"
                    )
                )
            } else {
                result = .success(())
            }
            settle(turnID: turnID, result: result)
        case .request(let request):
            await rejectUnattendedRequest(request)
        case .disconnected(let detail):
            let current = waiters.values
            waiters.removeAll()
            current.forEach {
                $0.resume(throwing: CodexAppServerError.disconnected(detail))
            }
        }
    }

    private func reconcileCompletion(threadID: String, turnID: String) async {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { return }
            guard waiters[turnID] != nil else { return }
            do {
                let response = try await client.request(
                    method: "thread/read",
                    params: .object([
                        "threadId": .string(threadID),
                        "includeTurns": .bool(true),
                    ])
                )
                let turns = response["thread"]?["turns"]?.arrayValue ?? []
                guard
                    let turn = turns.last(where: {
                        $0["id"]?.stringValue == turnID
                    }),
                    let status = turn["status"]?.stringValue,
                    status != "inProgress"
                else { continue }
                if status == "failed" || status == "interrupted" || status == "cancelled" {
                    settle(
                        turnID: turnID,
                        result: .failure(
                            .turnFailed(
                                turn["error"]?["message"]?.stringValue
                                    ?? "Codex 任务未完成（\(status)）"
                            )
                        )
                    )
                } else {
                    settle(turnID: turnID, result: .success(()))
                }
                return
            } catch {
                // Notification remains the fast path. A transient read error
                // only delays the next reconciliation attempt.
            }
        }
    }

    private func settle(
        turnID: String,
        result: Result<Void, CodexAgentError>
    ) {
        if let waiter = waiters.removeValue(forKey: turnID) {
            switch result {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        } else {
            completedTurns[turnID] = result
            if completedTurns.count > 64, let oldest = completedTurns.keys.first {
                completedTurns.removeValue(forKey: oldest)
            }
        }
    }

    private func rejectUnattendedRequest(_ request: CodexServerRequest) async {
        do {
            switch request.method {
            case "item/commandExecution/requestApproval",
                 "item/fileChange/requestApproval":
                try await client.respond(
                    to: request.id,
                    result: .object(["decision": .string("decline")])
                )
            case "item/tool/requestUserInput":
                var answers: [String: JSONValue] = [:]
                for question in request.params["questions"]?.arrayValue ?? [] {
                    if let id = question["id"]?.stringValue {
                        answers[id] = .object(["answers": .array([])])
                    }
                }
                try await client.respond(
                    to: request.id,
                    result: .object(["answers": .object(answers)])
                )
            case "item/permissions/requestApproval":
                try await client.respond(
                    to: request.id,
                    result: .object(["permissions": .object([:])])
                )
            case "mcpServer/elicitation/request":
                try await client.respond(
                    to: request.id,
                    result: .object([
                        "action": .string("decline"),
                        "content": .null,
                    ])
                )
            default:
                try await client.respondWithError(
                    to: request.id,
                    message: "无人值守微信渠道不支持此交互请求"
                )
            }
        } catch {
            await client.stop()
        }
    }
}
