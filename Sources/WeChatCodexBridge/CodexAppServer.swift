import Foundation

public enum CodexWireMessage: Equatable, Sendable {
    case response(id: Int, result: JSONValue)
    case failure(id: Int, error: JSONValue)
    case notification(method: String, params: JSONValue)
    case request(id: JSONValue, method: String, params: JSONValue)

    public static func decode(line: String) throws -> CodexWireMessage {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        guard let object = value.objectValue else {
            throw CodexAppServerError.invalidMessage
        }
        if let method = object["method"]?.stringValue {
            let params = object["params"] ?? .object([:])
            if let id = object["id"] {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }
        guard let id = object["id"]?.intValue else {
            throw CodexAppServerError.invalidMessage
        }
        if let error = object["error"] {
            return .failure(id: id, error: error)
        }
        return .response(id: id, result: object["result"] ?? .null)
    }
}

public struct CodexServerRequest: Sendable {
    public let id: JSONValue
    public let method: String
    public let params: JSONValue
}

public enum CodexServerEvent: Sendable {
    case notification(method: String, params: JSONValue)
    case request(CodexServerRequest)
    case disconnected(String)
}

public enum CodexAppServerError: LocalizedError, Sendable {
    case executableNotFound
    case launch(String)
    case disconnected(String)
    case invalidMessage
    case requestTimedOut(String)
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "未找到 Codex CLI；请安装 Codex App/CLI 或使用 --codex 指定路径"
        case .launch(let detail): "无法启动 codex app-server：\(detail)"
        case .disconnected(let detail):
            detail.isEmpty ? "Codex 连接已断开" : "Codex 连接已断开：\(detail)"
        case .invalidMessage: "Codex 返回了无法识别的数据"
        case .requestTimedOut(let method): "Codex 请求超时（\(method)）"
        case .remote(let detail): detail
        }
    }
}

public actor CodexAppServer {
    public nonisolated let events: AsyncStream<CodexServerEvent>

    private let eventContinuation: AsyncStream<CodexServerEvent>.Continuation
    private let executableOverride: URL?
    private let requestTimeoutNanoseconds: UInt64
    private let outputQueue = DispatchQueue(
        label: "wechat-codex.app-server.stdout",
        qos: .userInitiated
    )
    private let errorQueue = DispatchQueue(
        label: "wechat-codex.app-server.stderr",
        qos: .utility
    )
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var outputContinuation: AsyncStream<String>.Continuation?
    private var startTask: Task<Void, Error>?
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var ready = false
    private var stopping = false

    public init(
        executable: URL? = nil,
        requestTimeoutNanoseconds: UInt64 = 45_000_000_000
    ) {
        executableOverride = executable
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
        let stream = AsyncStream.makeStream(of: CodexServerEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        outputTask?.cancel()
        outputContinuation?.finish()
        process?.terminate()
        eventContinuation.finish()
    }

    public func start() async throws {
        if ready { return }
        if let startTask {
            try await startTask.value
            return
        }
        let task = Task { try await self.launchAndInitialize() }
        startTask = task
        do {
            try await task.value
            startTask = nil
        } catch {
            startTask = nil
            throw error
        }
    }

    public func request(
        method: String,
        params: JSONValue = .object([:])
    ) async throws -> JSONValue {
        try await start()
        return try await sendRequest(method: method, params: params)
    }

    public func respond(to id: JSONValue, result: JSONValue) throws {
        try write(["id": id, "result": result])
    }

    public func respondWithError(
        to id: JSONValue,
        code: Int = -32601,
        message: String
    ) throws {
        try write([
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
    }

    public func stop() {
        stopping = true
        ready = false
        startTask?.cancel()
        startTask = nil
        let child = process
        process = nil
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputContinuation?.finish()
        outputContinuation = nil
        outputTask?.cancel()
        outputTask = nil
        child?.terminate()
        failPending(CodexAppServerError.disconnected(""))
    }

    private func launchAndInitialize() async throws {
        guard let executable = executableOverride ?? Self.locateCodex() else {
            throw CodexAppServerError.executableNotFound
        }
        stopping = false
        let child = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        child.executableURL = executable
        child.arguments = ["app-server"]
        child.environment = Self.appServerEnvironment()
        child.standardInput = standardInput
        child.standardOutput = standardOutput
        child.standardError = standardError
        child.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { [weak self] in await self?.didTerminate(status: status) }
        }
        do { try child.run() }
        catch { throw CodexAppServerError.launch(error.localizedDescription) }
        process = child
        inputHandle = standardInput.fileHandleForWriting
        outputHandle = standardOutput.fileHandleForReading
        errorHandle = standardError.fileHandleForReading
        beginReading()
        do {
            _ = try await sendRequest(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("wechat_codex_bridge"),
                        "title": .string("WeChat Codex Bridge"),
                        "version": .string("0.1.0"),
                    ]),
                ])
            )
            try write([
                "method": .string("initialized"),
                "params": .object([:]),
            ])
            ready = true
        } catch {
            stop()
            throw error
        }
    }

    private func beginReading() {
        guard let outputHandle, let errorHandle else { return }
        let stream = AsyncStream.makeStream(of: String.self)
        outputContinuation = stream.continuation
        outputTask = Task { [weak self] in
            for await line in stream.stream {
                guard !Task.isCancelled else { return }
                await self?.receive(line: line)
            }
        }
        outputQueue.async { [weak self] in
            var buffer = JSONLineBuffer()
            while true {
                let data = outputHandle.availableData
                guard !data.isEmpty else {
                    stream.continuation.finish()
                    Task { [weak self] in await self?.readerEnded() }
                    return
                }
                do {
                    for line in try buffer.append(data) {
                        stream.continuation.yield(line)
                    }
                } catch {
                    stream.continuation.finish()
                    Task { [weak self] in await self?.readerFailed() }
                    return
                }
            }
        }
        errorQueue.async {
            while !errorHandle.availableData.isEmpty {}
        }
    }

    private func sendRequest(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(
                        nanoseconds: self.requestTimeoutNanoseconds
                    )
                }
                catch { return }
                await self.timedOut(id: id, method: method)
            }
            pending[id] = PendingRequest(continuation: continuation, timeout: timeout)
            do {
                try write([
                    "id": .number(Double(id)),
                    "method": .string(method),
                    "params": params,
                ])
            } catch {
                pending.removeValue(forKey: id)?.timeout.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func write(_ object: [String: JSONValue]) throws {
        guard let inputHandle, process?.isRunning == true else {
            throw CodexAppServerError.disconnected("")
        }
        var data = try JSONEncoder().encode(JSONValue.object(object))
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(line: String) {
        guard !stopping, process != nil else { return }
        do {
            switch try CodexWireMessage.decode(line: line) {
            case .response(let id, let result):
                guard let request = pending.removeValue(forKey: id) else { return }
                request.timeout.cancel()
                request.continuation.resume(returning: result)
            case .failure(let id, let error):
                guard let request = pending.removeValue(forKey: id) else { return }
                request.timeout.cancel()
                request.continuation.resume(
                    throwing: CodexAppServerError.remote(
                        error["message"]?.stringValue ?? error.prettyPrinted
                    )
                )
            case .notification(let method, let params):
                eventContinuation.yield(.notification(method: method, params: params))
            case .request(let id, let method, let params):
                eventContinuation.yield(
                    .request(CodexServerRequest(id: id, method: method, params: params))
                )
            }
        } catch {
            failPending(CodexAppServerError.invalidMessage)
            process?.terminate()
        }
    }

    private func timedOut(id: Int, method: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(
            throwing: CodexAppServerError.requestTimedOut(method)
        )
        if ["initialize", "thread/start", "thread/resume", "turn/start"]
            .contains(method)
        {
            ready = false
            failPending(CodexAppServerError.disconnected("请求超时"))
            process?.terminate()
        }
    }

    private func readerEnded() {
        guard !stopping, process?.isRunning == true else { return }
        failPending(CodexAppServerError.disconnected("响应流意外结束"))
        process?.terminate()
    }

    private func readerFailed() {
        guard !stopping else { return }
        process?.terminate()
    }

    private func didTerminate(status: Int32) {
        guard process != nil else { return }
        let expected = stopping
        ready = false
        process = nil
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputContinuation?.finish()
        outputContinuation = nil
        outputTask?.cancel()
        outputTask = nil
        let detail = status == 0 ? "" : "进程退出码 \(status)"
        failPending(CodexAppServerError.disconnected(detail))
        if !expected { eventContinuation.yield(.disconnected(detail)) }
    }

    private func failPending(_ error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private static func locateCodex() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func appServerEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        environment["PATH"] = (preferred + existing)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }
}

private struct PendingRequest {
    let continuation: CheckedContinuation<JSONValue, Error>
    let timeout: Task<Void, Never>
}

public struct JSONLineBuffer {
    private static let maximumBytes = 16 * 1_024 * 1_024
    private var data = Data()

    public init() {}

    public mutating func append(_ next: Data) throws -> [String] {
        data.append(next)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data[..<newline]
            data.removeSubrange(...newline)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        guard data.count <= Self.maximumBytes else {
            throw CodexAppServerError.invalidMessage
        }
        return lines
    }
}
