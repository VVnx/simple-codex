import Foundation
import XCTest
@testable import WeChatCodexBridge

final class WeChatCodexBridgeTests: XCTestCase {
    func testMessageFilterAcceptsCompletedOwnerText() {
        let message = WeChatInboundMessage(
            messageID: 42,
            fromUserID: "owner",
            toUserID: "bot",
            groupID: nil,
            messageType: 1,
            messageState: 2,
            itemList: [
                WeChatMessageItem(
                    type: 1,
                    textItem: .init(text: "  帮我整理这个目录  ")
                ),
            ],
            contextToken: "context"
        )

        XCTAssertEqual(
            BridgeMessageFilter.accept(message, accountID: "bot"),
            AcceptedWeChatMessage(
                messageID: 42,
                sender: "owner",
                contextToken: "context",
                text: "帮我整理这个目录"
            )
        )
    }

    func testMessageFilterRejectsGroupAndUnsupportedMedia() {
        let group = inbound(groupID: "group", itemType: 1)
        let image = inbound(groupID: nil, itemType: 2)

        XCTAssertNil(BridgeMessageFilter.accept(group, accountID: "bot"))
        XCTAssertNil(BridgeMessageFilter.accept(image, accountID: "bot"))
    }

    func testStateStoreRoundTripsAndUsesRestrictivePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeChatCodexBridgeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BridgeStateStore(directory: directory)
        var state = BridgeState()
        state.accountID = "bot"
        state.ownerUserID = "owner"
        state.cursor = "cursor"
        state.pendingMessages = [
            PendingMessage(
                messageID: 1,
                text: "hello",
                contextToken: "context",
                runID: "run",
                phase: .pendingCodex,
                replyChunks: [],
                clientIDs: [],
                nextReplyIndex: 0
            ),
        ]

        try store.save(state)

        XCTAssertEqual(try store.load(), state)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("state.json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStateStoreCanReserveReplyHeadroom() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeChatCodexBridgeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BridgeStateStore(directory: directory)
        var state = BridgeState()
        state.pendingMessages = (0..<14).map { index in
            PendingMessage(
                messageID: Int64(index),
                text: String(repeating: "字", count: 40_000),
                contextToken: "context",
                runID: "run-\(index)",
                phase: .pendingCodex,
                replyChunks: [],
                clientIDs: [],
                nextReplyIndex: 0
            )
        }

        XCTAssertTrue(try store.fits(state))
        XCTAssertFalse(try store.fits(state, reservingBytes: 512 * 1_024))
    }

    func testReplySplittingPreservesLimitAndMarksTruncation() {
        let text = String(repeating: "a", count: 64 * 4_000 + 500)
        let chunks = WeChatCodexBridge.splitMessage(text)

        XCTAssertEqual(chunks.count, 64)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 4_000 })
        XCTAssertTrue(chunks.last?.hasSuffix("[结果过长，已截断]") == true)
    }

    func testCodexWireDecoderSeparatesResponseAndServerRequest() throws {
        XCTAssertEqual(
            try CodexWireMessage.decode(line: #"{"id":7,"result":{"ok":true}}"#),
            .response(id: 7, result: .object(["ok": .bool(true)]))
        )
        XCTAssertEqual(
            try CodexWireMessage.decode(
                line: #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{}}"#
            ),
            .request(
                id: .string("approval-1"),
                method: "item/commandExecution/requestApproval",
                params: .object([:])
            )
        )
    }

    func testCodexRequestBuilderPinsUnattendedWorkspaceSafety() {
        let workspace = URL(fileURLWithPath: "/tmp/wechat-codex-workspace")
        let configuration = CodexAgentConfiguration(
            workspace: workspace,
            sandbox: .workspaceWrite
        )

        let thread = CodexRequestBuilder.threadStart(
            configuration: configuration
        )
        let turn = CodexRequestBuilder.turnStart(
            threadID: "thread-1",
            text: "hello",
            configuration: configuration
        )

        XCTAssertEqual(thread["approvalPolicy"]?.stringValue, "never")
        XCTAssertEqual(thread["sandbox"]?.stringValue, "workspace-write")
        XCTAssertEqual(turn["approvalPolicy"]?.stringValue, "never")
        XCTAssertEqual(
            turn["sandboxPolicy"]?["type"]?.stringValue,
            "workspaceWrite"
        )
        XCTAssertEqual(
            turn["sandboxPolicy"]?["networkAccess"]?.boolValue,
            false
        )
        XCTAssertEqual(
            turn["sandboxPolicy"]?["writableRoots"]?.arrayValue,
            [.string(workspace.path)]
        )
    }

    func testWeChatEndpointValidationRejectsRedirectsAndLookalikeHosts() {
        XCTAssertNoThrow(
            try WeChatClient.validateAPIBaseURL(
                URL(string: "https://ilinkai.weixin.qq.com")!
            )
        )
        XCTAssertThrowsError(
            try WeChatClient.validateAPIBaseURL(
                URL(string: "https://weixin.qq.com.evil.example")!
            )
        )
        XCTAssertThrowsError(
            try WeChatClient.validateAPIBaseURL(
                URL(string: "https://ilinkai.weixin.qq.com/path")!
            )
        )
    }

    private func inbound(groupID: String?, itemType: Int) -> WeChatInboundMessage {
        WeChatInboundMessage(
            messageID: 1,
            fromUserID: "owner",
            toUserID: "bot",
            groupID: groupID,
            messageType: 1,
            messageState: 2,
            itemList: [
                WeChatMessageItem(
                    type: itemType,
                    textItem: .init(text: "hello")
                ),
            ],
            contextToken: "context"
        )
    }
}
