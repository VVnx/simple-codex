import Foundation

public struct AcceptedWeChatMessage: Equatable, Sendable {
    public let messageID: Int64
    public let sender: String
    public let contextToken: String
    public let text: String
}

public enum BridgeMessageFilter {
    public static func accept(
        _ message: WeChatInboundMessage,
        accountID: String
    ) -> AcceptedWeChatMessage? {
        guard
            message.messageType == 1,
            message.messageState == 2,
            message.groupID == nil || message.groupID?.isEmpty == true,
            message.toUserID == nil
                || message.toUserID?.isEmpty == true
                || message.toUserID == accountID,
            let messageID = message.messageID,
            let sender = message.fromUserID,
            !sender.isEmpty,
            sender.utf8.count <= 4_096,
            let contextToken = message.contextToken,
            !contextToken.isEmpty,
            contextToken.utf8.count <= 65_536,
            let items = message.itemList,
            !items.isEmpty,
            items.allSatisfy(\.isSupported),
            let text = message.text,
            text.utf8.count <= 128 * 1_024
        else { return nil }
        return AcceptedWeChatMessage(
            messageID: messageID,
            sender: sender,
            contextToken: contextToken,
            text: text
        )
    }
}

public enum WeChatCodexBridgeError: LocalizedError, Sendable {
    case verificationBlocked
    case loginExpired
    case loginAlreadyBound
    case ownerConflict
    case staleCredentials

    public var errorDescription: String? {
        switch self {
        case .verificationBlocked: "微信验证码尝试次数过多，请稍后重新扫码"
        case .loginExpired: "微信二维码已连续过期，请重新启动工具"
        case .loginAlreadyBound: "该二维码对应的微信机器人已绑定"
        case .ownerConflict: "本地保存的主人和本次登录返回的主人不一致；请先 --logout"
        case .staleCredentials: "微信登录已失效；请运行 --logout 后重新扫码"
        }
    }
}

public final class WeChatCodexBridge: @unchecked Sendable {
    public typealias Logger = @Sendable (String) -> Void
    public typealias QRCodeHandler = @Sendable (String) async throws -> Void
    public typealias VerificationCodeProvider = @Sendable () async -> String?

    private let api: WeChatClient
    private let credentialStore: KeychainCredentialStore
    private let stateStore: BridgeStateStore
    private let agent: CodexAgent
    private let logger: Logger

    public init(
        api: WeChatClient = WeChatClient(),
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        stateStore: BridgeStateStore = BridgeStateStore(),
        agent: CodexAgent,
        logger: @escaping Logger = { _ in }
    ) {
        self.api = api
        self.credentialStore = credentialStore
        self.stateStore = stateStore
        self.agent = agent
        self.logger = logger
    }

    public func run(
        onQRCode: @escaping QRCodeHandler,
        verificationCode: @escaping VerificationCodeProvider
    ) async throws {
        try stateStore.acquireExclusiveAccess()
        defer { stateStore.releaseExclusiveAccess() }

        var state = try stateStore.load()
        let credentials: WeChatCredentials
        if let stored = try credentialStore.load() {
            credentials = stored
        } else {
            credentials = try await login(
                state: &state,
                onQRCode: onQRCode,
                verificationCode: verificationCode
            )
        }
        try reconcile(credentials: credentials, state: &state)
        recoverInterruptedWork(state: &state)
        try stateStore.save(state)

        logger("微信已连接，开始监听主人私聊。工作目录：\(stateStore.directory.path)")
        try? await api.notifyStarted(credentials: credentials)
        do {
            try await monitor(credentials: credentials, state: &state)
            try? await api.notifyStopped(credentials: credentials)
            await agent.stop()
        } catch {
            try? await api.notifyStopped(credentials: credentials)
            await agent.stop()
            throw error
        }
    }

    private func login(
        state: inout BridgeState,
        onQRCode: @escaping QRCodeHandler,
        verificationCode: @escaping VerificationCodeProvider
    ) async throws -> WeChatCredentials {
        var expirationCount = 0
        var redirectCount = 0
        while expirationCount <= 3 {
            let code = try await api.fetchLoginQRCode()
            try await onQRCode(code.content)
            var statusBaseURL = WeChatClient.loginBaseURL
            var pendingVerificationCode: String?
            while true {
                let result = try await api.pollLoginQRCode(
                    identifier: code.identifier,
                    baseURL: statusBaseURL,
                    verificationCode: pendingVerificationCode
                )
                pendingVerificationCode = nil
                switch result {
                case .waiting:
                    break
                case .scanned:
                    logger("二维码已扫描，请在微信中确认。")
                case .verificationRequired:
                    pendingVerificationCode = await verificationCode()?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                case .verificationBlocked:
                    throw WeChatCodexBridgeError.verificationBlocked
                case .expired:
                    expirationCount += 1
                    break
                case .redirected(let url):
                    redirectCount += 1
                    guard redirectCount <= 3 else {
                        throw WeChatAPIError.invalidEndpoint
                    }
                    statusBaseURL = url
                case .alreadyConnected:
                    throw WeChatCodexBridgeError.loginAlreadyBound
                case .confirmed(let credentials):
                    try credentialStore.save(credentials)
                    state = BridgeState()
                    state.accountID = credentials.accountID
                    state.ownerUserID = credentials.ownerUserID.isEmpty
                        ? nil : credentials.ownerUserID
                    do { try stateStore.save(state) }
                    catch {
                        try? credentialStore.delete()
                        throw error
                    }
                    return credentials
                }
                if case .expired = result { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw WeChatCodexBridgeError.loginExpired
    }

    private func reconcile(
        credentials: WeChatCredentials,
        state: inout BridgeState
    ) throws {
        if let accountID = state.accountID, accountID != credentials.accountID {
            state = BridgeState()
        }
        state.accountID = credentials.accountID
        if !credentials.ownerUserID.isEmpty {
            if let owner = state.ownerUserID, owner != credentials.ownerUserID {
                throw WeChatCodexBridgeError.ownerConflict
            }
            state.ownerUserID = credentials.ownerUserID
        }
    }

    private func recoverInterruptedWork(state: inout BridgeState) {
        for index in state.pendingMessages.indices
        where state.pendingMessages[index].phase == .codexRunning {
            setReply(
                "上次任务在工具退出或断开时中止。为避免重复执行，我没有自动重跑；请重新发送任务。",
                message: &state.pendingMessages[index]
            )
        }
    }

    private func monitor(
        credentials: WeChatCredentials,
        state: inout BridgeState
    ) async throws {
        var timeoutMilliseconds = 35_000
        var retryCount = 0
        while !Task.isCancelled {
            do {
                while !state.pendingMessages.isEmpty {
                    try await processFirstPending(
                        credentials: credentials,
                        state: &state
                    )
                }
                let oldCursor = state.cursor
                let response = try await api.getUpdates(
                    credentials: credentials,
                    cursor: state.cursor,
                    timeoutMilliseconds: timeoutMilliseconds
                )
                if response.errorCode == -14 || response.ret == -14 {
                    throw WeChatCodexBridgeError.staleCredentials
                }
                if let ret = response.ret, ret != 0 {
                    throw WeChatAPIError.remote(
                        response.errorMessage ?? "微信消息同步失败"
                    )
                }
                if let code = response.errorCode, code != 0 {
                    throw WeChatAPIError.remote(
                        response.errorMessage ?? "微信消息同步失败（\(code)）"
                    )
                }
                let queueFull = try accept(
                    response.messages ?? [],
                    nextCursor: response.cursor,
                    credentials: credentials,
                    state: &state
                )
                timeoutMilliseconds = max(
                    5_000,
                    min(response.longPollingTimeoutMilliseconds ?? 35_000, 120_000)
                )
                retryCount = 0
                if queueFull || (state.cursor == oldCursor && state.pendingMessages.isEmpty) {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch is CancellationError {
                return
            } catch let error as WeChatCodexBridgeError {
                throw error
            } catch let error as BridgeStateStoreError {
                throw error
            } catch {
                if case WeChatAPIError.staleCredentials = error {
                    throw WeChatCodexBridgeError.staleCredentials
                }
                if case WeChatAPIError.http(let status) = error,
                   status == 401 || status == 403
                {
                    throw WeChatCodexBridgeError.staleCredentials
                }
                retryCount += 1
                logger("微信连接暂时失败，准备重试：\(userFacing(error))")
                let seconds = UInt64(min(retryCount, 15))
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    private func accept(
        _ messages: [WeChatInboundMessage],
        nextCursor: String?,
        credentials: WeChatCredentials,
        state: inout BridgeState
    ) throws -> Bool {
        let processed = Set(state.processedMessageIDs)
        var queued = Set(state.pendingMessages.map(\.messageID))
        var queueFull = false
        for message in messages {
            guard let inbound = BridgeMessageFilter.accept(
                message,
                accountID: credentials.accountID
            ) else { continue }
            if let owner = state.ownerUserID, inbound.sender != owner { continue }
            guard
                !processed.contains(inbound.messageID),
                !queued.contains(inbound.messageID)
            else { continue }
            guard state.pendingMessages.count < 32 else {
                queueFull = true
                break
            }
            var candidate = state
            if candidate.ownerUserID == nil {
                candidate.ownerUserID = inbound.sender
            }
            let runID = UUID().uuidString
            candidate.pendingMessages.append(
                PendingMessage(
                    messageID: inbound.messageID,
                    text: inbound.text,
                    contextToken: inbound.contextToken,
                    runID: runID,
                    phase: .pendingCodex,
                    replyChunks: [],
                    clientIDs: [],
                    nextReplyIndex: 0
                )
            )
            guard try stateStore.fits(candidate, reservingBytes: 512 * 1_024)
            else {
                queueFull = true
                break
            }
            state = candidate
            queued.insert(inbound.messageID)
        }
        if !queueFull, let nextCursor, !nextCursor.isEmpty {
            var candidate = state
            candidate.cursor = nextCursor
            if try stateStore.fits(candidate, reservingBytes: 512 * 1_024) {
                state = candidate
            } else {
                queueFull = true
            }
        }
        try stateStore.save(state)
        if state.ownerUserID != nil && credentials.ownerUserID.isEmpty {
            logger("已由第一条有效私聊固定唯一主人。")
        }
        return queueFull
    }

    private func processFirstPending(
        credentials: WeChatCredentials,
        state: inout BridgeState
    ) async throws {
        guard !state.pendingMessages.isEmpty, let owner = state.ownerUserID else { return }
        switch state.pendingMessages[0].phase {
        case .pendingCodex:
            let message = state.pendingMessages[0]
            state.pendingMessages[0].phase = .codexRunning
            try stateStore.save(state)
            logger("收到微信任务 #\(message.messageID)，交给 Codex。")
            let reply: String
            do {
                let result = try await agent.run(
                    text: message.text,
                    preferredThreadID: state.threadID
                )
                state.threadID = result.threadID
                reply = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? "任务已完成，但没有可发送的文字结果。" : result.text
            } catch {
                reply = "任务未完成：\(userFacing(error))"
            }
            guard
                !state.pendingMessages.isEmpty,
                state.pendingMessages[0].runID == message.runID
            else { throw BridgeStateStoreError.corruptState }
            setReply(reply, message: &state.pendingMessages[0])
            try stateStore.save(state)
        case .codexRunning:
            recoverInterruptedWork(state: &state)
            try stateStore.save(state)
        case .pendingReply:
            var message = state.pendingMessages[0]
            while message.nextReplyIndex < message.replyChunks.count {
                let index = message.nextReplyIndex
                try await api.sendText(
                    credentials: credentials,
                    ownerUserID: owner,
                    contextToken: message.contextToken,
                    text: message.replyChunks[index],
                    clientID: message.clientIDs[index],
                    runID: message.runID
                )
                state.pendingMessages[0].nextReplyIndex += 1
                try stateStore.save(state)
                message = state.pendingMessages[0]
            }
            let completedID = message.messageID
            state.pendingMessages.removeFirst()
            state.processedMessageIDs.removeAll { $0 == completedID }
            state.processedMessageIDs.append(completedID)
            if state.processedMessageIDs.count > 512 {
                state.processedMessageIDs.removeFirst(
                    state.processedMessageIDs.count - 512
                )
            }
            try stateStore.save(state)
            logger("微信任务 #\(completedID) 已回复。")
        }
    }

    private func setReply(_ text: String, message: inout PendingMessage) {
        let chunks = Self.splitMessage(text)
        message.text = ""
        message.phase = .pendingReply
        message.replyChunks = chunks
        message.clientIDs = chunks.indices.map { "\(message.runID)-\($0)" }
        message.nextReplyIndex = 0
    }

    public static func splitMessage(_ raw: String) -> [String] {
        let marker = "\n\n[结果过长，已截断]"
        var remaining = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else {
            return ["任务已完成，但没有可发送的文字结果。"]
        }
        var chunks: [String] = []
        while !remaining.isEmpty, chunks.count < 64 {
            let last = chunks.count == 63
            let truncating = last && remaining.count > 4_000
            let limit = truncating ? 4_000 - marker.count : 4_000
            let end = remaining.index(
                remaining.startIndex,
                offsetBy: min(limit, remaining.count)
            )
            let candidate = String(remaining[..<end])
            let split: String.Index
            if !last,
               end != remaining.endIndex,
               let newline = candidate.lastIndex(of: "\n"),
               candidate.distance(from: newline, to: candidate.endIndex) < 600
            {
                split = newline
            } else {
                split = end
            }
            let chunk = String(remaining[..<split])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(truncating ? chunk + marker : chunk) }
            if last { break }
            remaining = String(remaining[split...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return chunks.isEmpty ? ["任务已完成，但没有可发送的文字结果。"] : chunks
    }

    private func userFacing(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty
        {
            return description
        }
        return error.localizedDescription
    }
}
