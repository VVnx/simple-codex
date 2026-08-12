import Foundation

public final class WeChatClient: NSObject, @unchecked Sendable {
    public static let protocolVersion = "2.4.6"
    public static let protocolClientVersion = "132102"
    public static let loginBaseURL = URL(
        string: "https://ilinkai.weixin.qq.com"
    )!

    private let session: URLSession
    private let delegate: BoundedSessionDelegate
    private let botAgent: String

    public init(appVersion: String = "0.1.0") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = BoundedSessionDelegate(maximumBytes: 1_048_576)
        self.delegate = delegate
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let safeVersion = String(
            appVersion.filter {
                $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0))
            }.prefix(32)
        )
        botAgent = "WeChatCodexBridge/\(safeVersion.isEmpty ? "development" : safeVersion)"
    }

    deinit { session.invalidateAndCancel() }

    public func fetchLoginQRCode() async throws -> WeChatLoginQRCode {
        let url = try endpoint(
            baseURL: Self.loginBaseURL,
            path: "ilink/bot/get_bot_qrcode",
            queryItems: [URLQueryItem(name: "bot_type", value: "3")]
        )
        let response: LoginQRCodeResponse = try await post(
            url: url,
            body: LoginQRCodeRequest(localTokenList: []),
            token: nil,
            timeout: 15
        )
        guard
            !response.identifier.isEmpty,
            response.identifier.utf8.count <= 4_096,
            !response.content.isEmpty,
            response.content.utf8.count <= 4_096
        else { throw WeChatAPIError.invalidResponse }
        return WeChatLoginQRCode(
            identifier: response.identifier,
            content: response.content
        )
    }

    public func pollLoginQRCode(
        identifier: String,
        baseURL: URL,
        verificationCode: String?
    ) async throws -> WeChatLoginPollResult {
        guard
            !identifier.isEmpty,
            identifier.utf8.count <= 4_096,
            (verificationCode?.utf8.count ?? 0) <= 64
        else { throw WeChatAPIError.invalidResponse }
        var queryItems = [URLQueryItem(name: "qrcode", value: identifier)]
        if let verificationCode, !verificationCode.isEmpty {
            queryItems.append(
                URLQueryItem(name: "verify_code", value: verificationCode)
            )
        }
        let url = try endpoint(
            baseURL: baseURL,
            path: "ilink/bot/get_qrcode_status",
            queryItems: queryItems
        )
        let response: LoginStatusResponse = try await get(url: url, timeout: 40)
        switch response.status {
        case "wait": return .waiting
        case "scaned": return .scanned
        case "need_verifycode": return .verificationRequired
        case "verify_code_blocked": return .verificationBlocked
        case "expired": return .expired
        case "binded_redirect": return .alreadyConnected
        case "scaned_but_redirect":
            guard
                let host = response.redirectHost,
                let url = URL(string: "https://\(host)")
            else { throw WeChatAPIError.invalidEndpoint }
            return .redirected(try Self.validateAPIBaseURL(url))
        case "confirmed":
            guard
                let token = response.botToken,
                !token.isEmpty,
                token.utf8.count <= 65_536,
                let accountID = response.accountID,
                !accountID.isEmpty,
                accountID.utf8.count <= 4_096
            else { throw WeChatAPIError.missingCredentials }
            let owner = response.ownerUserID ?? ""
            guard owner.utf8.count <= 4_096 else {
                throw WeChatAPIError.invalidResponse
            }
            return .confirmed(
                WeChatCredentials(
                    accountID: accountID,
                    ownerUserID: owner,
                    botToken: token,
                    baseURL: try Self.loginResponseBaseURL(response.baseURL)
                )
            )
        default:
            throw WeChatAPIError.invalidResponse
        }
    }

    public func getUpdates(
        credentials: WeChatCredentials,
        cursor: String,
        timeoutMilliseconds: Int
    ) async throws -> WeChatUpdatesResponse {
        let timeout = TimeInterval(
            max(5_000, min(timeoutMilliseconds, 120_000)) + 5_000
        ) / 1_000
        return try await post(
            url: endpoint(
                baseURL: credentials.baseURL,
                path: "ilink/bot/getupdates"
            ),
            body: UpdatesRequest(cursor: cursor, baseInfo: baseInfo),
            token: credentials.botToken,
            timeout: timeout
        )
    }

    public func sendText(
        credentials: WeChatCredentials,
        ownerUserID: String,
        contextToken: String,
        text: String,
        clientID: String,
        runID: String
    ) async throws {
        guard !contextToken.isEmpty else { throw WeChatAPIError.invalidResponse }
        let response: BasicResponse = try await post(
            url: endpoint(
                baseURL: credentials.baseURL,
                path: "ilink/bot/sendmessage"
            ),
            body: SendMessageRequest(
                message: OutboundMessage(
                    fromUserID: "",
                    toUserID: ownerUserID,
                    clientID: clientID,
                    messageType: 2,
                    messageState: 2,
                    items: [OutboundItem(type: 1, text: OutboundText(text: text))],
                    contextToken: contextToken,
                    runID: runID
                ),
                baseInfo: baseInfo
            ),
            token: credentials.botToken,
            timeout: 15
        )
        try validate(response)
    }

    public func notifyStarted(credentials: WeChatCredentials) async throws {
        try await notify(credentials: credentials, path: "ilink/bot/msg/notifystart")
    }

    public func notifyStopped(credentials: WeChatCredentials) async throws {
        try await notify(credentials: credentials, path: "ilink/bot/msg/notifystop")
    }

    public static func validateAPIBaseURL(_ url: URL) throws -> URL {
        guard
            url.scheme?.lowercased() == "https",
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil,
            url.path.isEmpty || url.path == "/",
            url.port == nil || url.port == 443,
            let host = url.host?.lowercased(),
            host == "ilinkai.weixin.qq.com"
                || host.hasSuffix(".weixin.qq.com")
                || host.hasSuffix(".wechat.com")
        else { throw WeChatAPIError.invalidEndpoint }
        return url
    }

    private static func loginResponseBaseURL(_ raw: String?) throws -> URL {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return loginBaseURL }
        guard raw.utf8.count <= 4_096 else { throw WeChatAPIError.invalidEndpoint }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "https://\(value)")
        else { throw WeChatAPIError.invalidEndpoint }
        return try validateAPIBaseURL(url)
    }

    private var baseInfo: WireBaseInfo {
        WireBaseInfo(channelVersion: Self.protocolVersion, botAgent: botAgent)
    }

    private func notify(credentials: WeChatCredentials, path: String) async throws {
        let response: BasicResponse = try await post(
            url: endpoint(baseURL: credentials.baseURL, path: path),
            body: NotifyRequest(baseInfo: baseInfo),
            token: credentials.botToken,
            timeout: 10
        )
        try validate(response)
    }

    private func validate(_ response: BasicResponse) throws {
        if response.ret == -14 || response.errorCode == -14 {
            throw WeChatAPIError.staleCredentials
        }
        guard
            response.ret == nil || response.ret == 0,
            response.errorCode == nil || response.errorCode == 0
        else {
            throw WeChatAPIError.remote(response.errorMessage ?? "微信服务拒绝了请求")
        }
    }

    private func endpoint(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        let trusted = try Self.validateAPIBaseURL(baseURL)
        var components = URLComponents(
            url: trusted.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw WeChatAPIError.invalidEndpoint }
        return url
    }

    private func get<Response: Decodable>(
        url: URL,
        timeout: TimeInterval
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        addHeaders(to: &request, authenticatedShape: false)
        return try await execute(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        url: URL,
        body: Body,
        token: String?,
        timeout: TimeInterval
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)
        addHeaders(to: &request, authenticatedShape: true)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await execute(request)
    }

    private func execute<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await delegate.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw WeChatAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WeChatAPIError.http(http.statusCode)
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw WeChatAPIError.invalidResponse }
    }

    private func addHeaders(to request: inout URLRequest, authenticatedShape: Bool) {
        request.setValue("bot", forHTTPHeaderField: "iLink-App-Id")
        request.setValue(
            Self.protocolClientVersion,
            forHTTPHeaderField: "iLink-App-ClientVersion"
        )
        guard authenticatedShape else { return }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ilink_bot_token", forHTTPHeaderField: "AuthorizationType")
        let random = UInt32.random(in: UInt32.min...UInt32.max)
        request.setValue(
            Data(String(random).utf8).base64EncodedString(),
            forHTTPHeaderField: "X-WECHAT-UIN"
        )
    }
}

private final class BoundedSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class RequestState {
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        var response: URLResponse?
        var data = Data()

        init(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            self.continuation = continuation
        }
    }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var requests: [Int: RequestState] = [:]

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func data(
        for request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                requests[task.taskIdentifier] = RequestState(continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in self?.cancel(task) }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            let state = remove(dataTask.taskIdentifier)
            completionHandler(.cancel)
            state?.continuation.resume(throwing: WeChatAPIError.responseTooLarge)
            return
        }
        lock.lock()
        requests[dataTask.taskIdentifier]?.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var overflow: RequestState?
        lock.lock()
        if let state = requests[dataTask.taskIdentifier] {
            if data.count > maximumBytes || state.data.count > maximumBytes - data.count {
                overflow = requests.removeValue(forKey: dataTask.taskIdentifier)
            } else {
                state.data.append(data)
            }
        }
        lock.unlock()
        guard let overflow else { return }
        dataTask.cancel()
        overflow.continuation.resume(throwing: WeChatAPIError.responseTooLarge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let state = remove(task.taskIdentifier) else { return }
        if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: (state.data, response))
        } else {
            state.continuation.resume(throwing: WeChatAPIError.invalidResponse)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func cancel(_ task: URLSessionTask) {
        let state = remove(task.taskIdentifier)
        task.cancel()
        state?.continuation.resume(throwing: CancellationError())
    }

    private func remove(_ id: Int) -> RequestState? {
        lock.lock()
        defer { lock.unlock() }
        return requests.removeValue(forKey: id)
    }
}

private struct LoginQRCodeRequest: Encodable {
    let localTokenList: [String]
    enum CodingKeys: String, CodingKey { case localTokenList = "local_token_list" }
}

private struct LoginQRCodeResponse: Decodable {
    let identifier: String
    let content: String
    enum CodingKeys: String, CodingKey {
        case identifier = "qrcode"
        case content = "qrcode_img_content"
    }
}

private struct LoginStatusResponse: Decodable {
    let status: String
    let botToken: String?
    let accountID: String?
    let baseURL: String?
    let ownerUserID: String?
    let redirectHost: String?
    enum CodingKeys: String, CodingKey {
        case status
        case botToken = "bot_token"
        case accountID = "ilink_bot_id"
        case baseURL = "baseurl"
        case ownerUserID = "ilink_user_id"
        case redirectHost = "redirect_host"
    }
}

private struct WireBaseInfo: Codable {
    let channelVersion: String
    let botAgent: String
    enum CodingKeys: String, CodingKey {
        case channelVersion = "channel_version"
        case botAgent = "bot_agent"
    }
}

private struct UpdatesRequest: Encodable {
    let cursor: String
    let baseInfo: WireBaseInfo
    enum CodingKeys: String, CodingKey {
        case cursor = "get_updates_buf"
        case baseInfo = "base_info"
    }
}

private struct BasicResponse: Codable {
    let ret: Int?
    let errorCode: Int?
    let errorMessage: String?
    enum CodingKeys: String, CodingKey {
        case ret
        case errorCode = "errcode"
        case errorMessage = "errmsg"
    }
}

private struct OutboundText: Encodable { let text: String }

private struct OutboundItem: Encodable {
    let type: Int
    let text: OutboundText
    enum CodingKeys: String, CodingKey { case type; case text = "text_item" }
}

private struct OutboundMessage: Encodable {
    let fromUserID: String
    let toUserID: String
    let clientID: String
    let messageType: Int
    let messageState: Int
    let items: [OutboundItem]
    let contextToken: String
    let runID: String
    enum CodingKeys: String, CodingKey {
        case fromUserID = "from_user_id"
        case toUserID = "to_user_id"
        case clientID = "client_id"
        case messageType = "message_type"
        case messageState = "message_state"
        case items = "item_list"
        case contextToken = "context_token"
        case runID = "run_id"
    }
}

private struct SendMessageRequest: Encodable {
    let message: OutboundMessage
    let baseInfo: WireBaseInfo
    enum CodingKeys: String, CodingKey {
        case message = "msg"
        case baseInfo = "base_info"
    }
}

private struct NotifyRequest: Encodable {
    let baseInfo: WireBaseInfo
    enum CodingKeys: String, CodingKey { case baseInfo = "base_info" }
}
