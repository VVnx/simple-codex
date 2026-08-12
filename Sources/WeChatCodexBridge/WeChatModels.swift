import Foundation

public struct WeChatCredentials: Codable, Equatable, Sendable {
    public let accountID: String
    public let ownerUserID: String
    public let botToken: String
    public let baseURL: URL

    public init(
        accountID: String,
        ownerUserID: String,
        botToken: String,
        baseURL: URL
    ) {
        self.accountID = accountID
        self.ownerUserID = ownerUserID
        self.botToken = botToken
        self.baseURL = baseURL
    }
}

public struct WeChatLoginQRCode: Equatable, Sendable {
    public let identifier: String
    public let content: String
}

public enum WeChatLoginPollResult: Equatable, Sendable {
    case waiting
    case scanned
    case verificationRequired
    case verificationBlocked
    case expired
    case redirected(URL)
    case alreadyConnected
    case confirmed(WeChatCredentials)
}

public struct WeChatMessageItem: Codable, Equatable, Sendable {
    public struct TextItem: Codable, Equatable, Sendable {
        public let text: String?

        public init(text: String?) { self.text = text }
    }

    public let type: Int?
    public let textItem: TextItem?
    public let voiceItem: TextItem?

    enum CodingKeys: String, CodingKey {
        case type
        case textItem = "text_item"
        case voiceItem = "voice_item"
    }

    public init(
        type: Int?,
        textItem: TextItem? = nil,
        voiceItem: TextItem? = nil
    ) {
        self.type = type
        self.textItem = textItem
        self.voiceItem = voiceItem
    }

    public var text: String? {
        let raw: String?
        switch type {
        case 1: raw = textItem?.text
        case 3: raw = voiceItem?.text
        default: raw = nil
        }
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    public var isSupported: Bool { type == 1 || type == 3 }
}

public struct WeChatInboundMessage: Codable, Equatable, Sendable {
    public let messageID: Int64?
    public let fromUserID: String?
    public let toUserID: String?
    public let groupID: String?
    public let messageType: Int?
    public let messageState: Int?
    public let itemList: [WeChatMessageItem]?
    public let contextToken: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case fromUserID = "from_user_id"
        case toUserID = "to_user_id"
        case groupID = "group_id"
        case messageType = "message_type"
        case messageState = "message_state"
        case itemList = "item_list"
        case contextToken = "context_token"
    }

    public init(
        messageID: Int64?,
        fromUserID: String?,
        toUserID: String?,
        groupID: String?,
        messageType: Int?,
        messageState: Int?,
        itemList: [WeChatMessageItem]?,
        contextToken: String?
    ) {
        self.messageID = messageID
        self.fromUserID = fromUserID
        self.toUserID = toUserID
        self.groupID = groupID
        self.messageType = messageType
        self.messageState = messageState
        self.itemList = itemList
        self.contextToken = contextToken
    }

    public var text: String? {
        itemList?.compactMap(\.text).first
    }
}

public struct WeChatUpdatesResponse: Codable, Equatable, Sendable {
    public let ret: Int?
    public let errorCode: Int?
    public let errorMessage: String?
    public let messages: [WeChatInboundMessage]?
    public let cursor: String?
    public let longPollingTimeoutMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case ret
        case errorCode = "errcode"
        case errorMessage = "errmsg"
        case messages = "msgs"
        case cursor = "get_updates_buf"
        case longPollingTimeoutMilliseconds = "longpolling_timeout_ms"
    }
}

public enum WeChatAPIError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case http(Int)
    case remote(String)
    case missingCredentials
    case staleCredentials

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "微信服务返回了不受信任的地址"
        case .invalidResponse: "微信服务返回了无法识别的数据"
        case .responseTooLarge: "微信服务返回的数据超过安全上限"
        case .http(let status): "微信服务暂时不可用（HTTP \(status)）"
        case .remote(let message): message
        case .missingCredentials: "微信登录确认缺少必要的账号信息"
        case .staleCredentials: "微信登录已失效，请重新扫码"
        }
    }
}
