import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import WeChatCodexBridge

@MainActor
final class StatusBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let workspaceDefaultsKey = "workspacePath"

    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength
    )
    private let menu = NSMenu()
    private let stateStore = BridgeStateStore()
    private let credentialStore = KeychainCredentialStore()
    private var bridgeTask: Task<Void, Never>?
    private var qrPanel: NSPanel?
    private var workspace: URL?
    private var status = "未启动"
    private var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = statusIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "微信 Codex"
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        restoreWorkspace()
        rebuildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridgeTask?.cancel()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private var isRunning: Bool { bridgeTask != nil }

    private func restoreWorkspace() {
        guard
            let path = UserDefaults.standard.string(
                forKey: Self.workspaceDefaultsKey
            ),
            !path.isEmpty
        else { return }
        workspace = validatedDirectory(URL(fileURLWithPath: path))
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let title = NSMenuItem(
            title: "微信 Codex",
            action: nil,
            keyEquivalent: ""
        )
        title.attributedTitle = NSAttributedString(
            string: "微信 Codex",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        title.isEnabled = false
        menu.addItem(title)

        let statusItem = NSMenuItem(
            title: "状态：\(status)",
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if let lastError {
            let errorItem = NSMenuItem(
                title: "⚠︎ \(bounded(lastError, maximum: 90))",
                action: nil,
                keyEquivalent: ""
            )
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        let workspaceTitle: String
        if let workspace {
            workspaceTitle = "工作目录：\(workspace.lastPathComponent)"
        } else {
            workspaceTitle = "工作目录：未选择"
        }
        let workspaceItem = NSMenuItem(
            title: workspaceTitle,
            action: #selector(chooseWorkspace),
            keyEquivalent: ""
        )
        workspaceItem.target = self
        workspaceItem.isEnabled = !isRunning
        menu.addItem(workspaceItem)

        if workspace != nil {
            let revealItem = NSMenuItem(
                title: "在 Finder 中打开工作目录",
                action: #selector(revealWorkspace),
                keyEquivalent: ""
            )
            revealItem.target = self
            menu.addItem(revealItem)
        }

        let runItem = NSMenuItem(
            title: isRunning ? "停止监听" : "连接微信并开始监听",
            action: isRunning ? #selector(stopBridge) : #selector(startBridge),
            keyEquivalent: ""
        )
        runItem.target = self
        runItem.isEnabled = isRunning || workspace != nil
        menu.addItem(runItem)

        menu.addItem(.separator())

        let logoutItem = NSMenuItem(
            title: "退出微信登录…",
            action: #selector(logout),
            keyEquivalent: ""
        )
        logoutItem.target = self
        logoutItem.isEnabled = !isRunning
        menu.addItem(logoutItem)

        let aboutItem = NSMenuItem(
            title: "关于微信 Codex",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func chooseWorkspace() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 工作目录"
        panel.prompt = "选择"
        panel.message = "微信任务会在这个目录中运行。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let workspace { panel.directoryURL = workspace }
        activate()
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard let validated = validatedDirectory(selected) else {
            presentError("所选路径不是可用的本地文件夹。")
            return
        }
        workspace = validated
        UserDefaults.standard.set(
            validated.path,
            forKey: Self.workspaceDefaultsKey
        )
        status = "工作目录已就绪"
        lastError = nil
        rebuildMenu()
    }

    @objc private func revealWorkspace() {
        guard let workspace else { return }
        NSWorkspace.shared.activateFileViewerSelecting([workspace])
    }

    @objc private func startBridge() {
        guard bridgeTask == nil, let workspace else { return }
        lastError = nil
        status = "正在连接"
        rebuildMenu()

        let appServer = CodexAppServer()
        let agent = CodexAgent(
            client: appServer,
            configuration: CodexAgentConfiguration(
                workspace: workspace,
                sandbox: .workspaceWrite
            )
        )
        let bridge = WeChatCodexBridge(
            credentialStore: credentialStore,
            stateStore: stateStore,
            agent: agent,
            logger: { [weak self] message in
                Task { @MainActor in self?.updateStatus(from: message) }
            }
        )
        bridgeTask = Task { [weak self] in
            do {
                try await bridge.run(
                    onQRCode: { [weak self] content in
                        try await self?.showQRCode(content)
                    },
                    verificationCode: { [weak self] in
                        await self?.requestVerificationCode()
                    }
                )
                self?.bridgeDidStop(error: nil)
            } catch is CancellationError {
                self?.bridgeDidStop(error: nil)
            } catch {
                self?.bridgeDidStop(error: userFacing(error))
            }
        }
    }

    @objc private func stopBridge() {
        status = "正在停止"
        rebuildMenu()
        bridgeTask?.cancel()
    }

    @objc private func logout() {
        guard !isRunning else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出微信登录？"
        alert.informativeText =
            "这会清除 Keychain 中的微信凭据，以及本机保存的主人、消息游标和 Codex 会话引用。"
        alert.addButton(withTitle: "退出登录")
        alert.addButton(withTitle: "取消")
        activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try stateStore.acquireExclusiveAccess()
            defer { stateStore.releaseExclusiveAccess() }
            try credentialStore.delete()
            try stateStore.clear()
            status = "已退出微信登录"
            lastError = nil
        } catch {
            presentError(userFacing(error))
        }
        rebuildMenu()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "微信 Codex"
        alert.informativeText = """
        一个纯 Swift 菜单栏小工具：把唯一主人的微信私聊交给本机 Codex 执行。

        当前支持文字和语音转写；默认仅允许写入所选工作目录，且不会等待远程审批。
        """
        alert.addButton(withTitle: "好")
        activate()
        alert.runModal()
    }

    @objc private func quit() {
        bridgeTask?.cancel()
        NSApp.terminate(nil)
    }

    private func updateStatus(from message: String) {
        if message.contains("开始监听") {
            status = "正在监听"
            closeQRCodePanel()
        } else if message.contains("交给 Codex") {
            status = "Codex 正在处理"
        } else if message.contains("已回复") {
            status = "正在监听"
        } else if message.contains("重试") {
            status = "正在重连"
        } else if message.contains("固定唯一主人") {
            status = "主人已绑定"
        } else {
            status = bounded(message, maximum: 48)
        }
        rebuildMenu()
    }

    private func bridgeDidStop(error: String?) {
        bridgeTask = nil
        closeQRCodePanel()
        if let error {
            status = "已停止"
            lastError = error
            presentError(error)
        } else {
            status = "已停止"
        }
        rebuildMenu()
    }

    private func showQRCode(_ content: String) async throws {
        guard let image = qrCodeImage(content) else {
            throw MenuBarError.qrCode
        }
        closeQRCodePanel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "连接微信"
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        let headline = NSTextField(labelWithString: "用微信扫描二维码")
        headline.font = .boldSystemFont(ofSize: 18)
        headline.alignment = .center
        headline.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(
            wrappingLabelWithString: "确认后，这个菜单栏工具会接收唯一主人的私聊任务。"
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.translatesAutoresizingMaskIntoConstraints = false
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headline)
        container.addSubview(imageView)
        container.addSubview(detail)
        panel.contentView = container
        NSLayoutConstraint.activate([
            headline.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            headline.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            headline.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            imageView.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 18),
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 260),
            imageView.heightAnchor.constraint(equalToConstant: 260),
            detail.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
            detail.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            detail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
        ])
        qrPanel = panel
        status = "等待扫码"
        rebuildMenu()
        activate()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func requestVerificationCode() async -> String? {
        let alert = NSAlert()
        alert.messageText = "输入微信验证码"
        alert.informativeText = "微信要求补充验证码后才能完成连接。"
        alert.addButton(withTitle: "提交")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "验证码"
        alert.accessoryView = field
        activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func closeQRCodePanel() {
        qrPanel?.close()
        qrPanel = nil
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "微信 Codex"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        activate()
        alert.runModal()
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum MenuBarError: LocalizedError {
    case qrCode

    var errorDescription: String? { "无法生成微信登录二维码" }
}

private func validatedDirectory(_ url: URL) -> URL? {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard
        FileManager.default.fileExists(
            atPath: resolved.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue
    else { return nil }
    return resolved
}

private func statusIcon() -> NSImage {
    if let symbol = NSImage(
        systemSymbolName: "bubble.left.and.bubble.right.fill",
        accessibilityDescription: "微信 Codex"
    ) {
        symbol.isTemplate = true
        return symbol
    }
    return NSImage(size: NSSize(width: 18, height: 18))
}

private func qrCodeImage(_ content: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(content.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(
        by: CGAffineTransform(scaleX: 12, y: 12)
    ) else { return nil }
    let context = CIContext()
    guard let image = context.createCGImage(output, from: output.extent) else {
        return nil
    }
    return NSImage(
        cgImage: image,
        size: NSSize(width: image.width, height: image.height)
    )
}

private func bounded(_ value: String, maximum: Int) -> String {
    guard value.count > maximum else { return value }
    return String(value.prefix(maximum - 1)) + "…"
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = StatusBarApp()
    app.delegate = delegate
    app.run()
}
