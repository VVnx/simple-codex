import Darwin
import Foundation

public struct PendingMessage: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case pendingCodex
        case codexRunning
        case pendingReply
    }

    public let messageID: Int64
    public var text: String
    public let contextToken: String
    public let runID: String
    public var phase: Phase
    public var replyChunks: [String]
    public var clientIDs: [String]
    public var nextReplyIndex: Int
}

public struct BridgeState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var accountID: String?
    public var ownerUserID: String?
    public var cursor = ""
    public var threadID: String?
    public var processedMessageIDs: [Int64] = []
    public var pendingMessages: [PendingMessage] = []

    public init() {}
}

public enum BridgeStateStoreError: LocalizedError, Sendable {
    case alreadyRunning
    case corruptState
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "已有另一份微信 Codex 工具正在运行"
        case .corruptState: "本地桥接状态已损坏"
        case .writeFailed: "无法保存本地桥接状态"
        }
    }
}

public final class BridgeStateStore: @unchecked Sendable {
    private static let maximumBytes = 2 * 1_024 * 1_024
    private let fileManager: FileManager
    public let directory: URL
    private let stateFile: URL
    private let lockFile: URL
    private var lockDescriptor: Int32 = -1

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WeChatCodexBridge")
        stateFile = self.directory.appendingPathComponent("state.json")
        lockFile = self.directory.appendingPathComponent("bridge.lock")
    }

    deinit { releaseExclusiveAccess() }

    public func acquireExclusiveAccess() throws {
        guard lockDescriptor < 0 else { return }
        try prepareDirectory()
        let descriptor = Darwin.open(
            lockFile.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw BridgeStateStoreError.writeFailed }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            throw BridgeStateStoreError.writeFailed
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw BridgeStateStoreError.alreadyRunning
            }
            throw BridgeStateStoreError.writeFailed
        }
        lockDescriptor = descriptor
    }

    public func releaseExclusiveAccess() {
        guard lockDescriptor >= 0 else { return }
        _ = flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        lockDescriptor = -1
    }

    public func load() throws -> BridgeState {
        guard fileManager.fileExists(atPath: stateFile.path) else {
            return BridgeState()
        }
        do {
            let data = try Data(contentsOf: stateFile)
            guard data.count <= Self.maximumBytes else {
                throw BridgeStateStoreError.corruptState
            }
            let state = try JSONDecoder().decode(BridgeState.self, from: data)
            guard Self.isValid(state) else { throw BridgeStateStoreError.corruptState }
            return state
        } catch let error as BridgeStateStoreError {
            throw error
        } catch {
            throw BridgeStateStoreError.corruptState
        }
    }

    public func save(_ state: BridgeState) throws {
        guard Self.isValid(state) else { throw BridgeStateStoreError.corruptState }
        do {
            try prepareDirectory()
            let data = try JSONEncoder().encode(state)
            guard data.count <= Self.maximumBytes else {
                throw BridgeStateStoreError.corruptState
            }
            try data.write(to: stateFile, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateFile.path
            )
        } catch let error as BridgeStateStoreError {
            throw error
        } catch {
            throw BridgeStateStoreError.writeFailed
        }
    }

    public func fits(
        _ state: BridgeState,
        reservingBytes: Int = 0
    ) throws -> Bool {
        guard Self.isValid(state), reservingBytes >= 0 else { return false }
        return try JSONEncoder().encode(state).count
            <= Self.maximumBytes - reservingBytes
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: stateFile.path) else { return }
        do { try fileManager.removeItem(at: stateFile) }
        catch { throw BridgeStateStoreError.writeFailed }
    }

    private func prepareDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch { throw BridgeStateStoreError.writeFailed }
    }

    private static func isValid(_ state: BridgeState) -> Bool {
        guard
            state.schemaVersion == 1,
            state.cursor.utf8.count <= 256 * 1_024,
            (state.accountID?.utf8.count ?? 0) <= 4_096,
            (state.ownerUserID?.utf8.count ?? 0) <= 4_096,
            (state.threadID?.utf8.count ?? 0) <= 8_192,
            state.processedMessageIDs.count <= 512,
            state.pendingMessages.count <= 32,
            Set(state.pendingMessages.map(\.messageID)).count == state.pendingMessages.count
        else { return false }
        return state.pendingMessages.allSatisfy { message in
            let replyIsValid = message.replyChunks.count <= 64
                && message.replyChunks.allSatisfy { !$0.isEmpty && $0.count <= 4_000 }
                && message.clientIDs.count == message.replyChunks.count
                && message.nextReplyIndex >= 0
                && message.nextReplyIndex <= message.replyChunks.count
            guard
                message.text.utf8.count <= 128 * 1_024,
                !message.contextToken.isEmpty,
                message.contextToken.utf8.count <= 65_536,
                !message.runID.isEmpty,
                message.runID.utf8.count <= 128,
                replyIsValid
            else { return false }
            switch message.phase {
            case .pendingCodex, .codexRunning:
                return !message.text.isEmpty && message.replyChunks.isEmpty
            case .pendingReply:
                return message.text.isEmpty && !message.replyChunks.isEmpty
            }
        }
    }
}
