import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import WeChatCodexBridge

@main
enum WeChatCodexCLI {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                print(Options.help)
                return
            }
            let stateStore = BridgeStateStore(directory: options.stateDirectory)
            let credentials = KeychainCredentialStore()
            if options.logout {
                try stateStore.acquireExclusiveAccess()
                defer { stateStore.releaseExclusiveAccess() }
                try credentials.delete()
                try stateStore.clear()
                print("已清除微信登录凭据和本地桥接状态。")
                return
            }
            guard let workspace = options.workspace else {
                throw CLIError.missingWorkspace
            }
            let validatedWorkspace = try validateWorkspace(workspace)
            let appServer = CodexAppServer(executable: options.codexExecutable)
            let agent = CodexAgent(
                client: appServer,
                configuration: CodexAgentConfiguration(
                    workspace: validatedWorkspace,
                    model: options.model,
                    reasoningEffort: options.effort,
                    sandbox: options.sandbox
                )
            )
            let bridge = WeChatCodexBridge(
                stateStore: stateStore,
                agent: agent,
                logger: { print("[wechat-codex] \($0)") }
            )
            try await bridge.run(
                onQRCode: { content in
                    let destination = stateStore.directory
                        .appendingPathComponent("login-qr.png")
                    try QRCodeWriter.write(content: content, to: destination)
                    print("请用微信扫描二维码：\(destination.path)")
                    if !options.noOpenQRCode {
                        await MainActor.run { _ = NSWorkspace.shared.open(destination) }
                    }
                },
                verificationCode: {
                    print("请输入微信验证码后回车：", terminator: "")
                    return readLine()
                }
            )
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            FileHandle.standardError.write(Data("错误：\(detail)\n".utf8))
            exit(1)
        }
    }

    private static func validateWorkspace(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else { throw CLIError.invalidWorkspace(resolved.path) }
        return resolved
    }
}

private enum CLIError: LocalizedError {
    case missingWorkspace
    case invalidWorkspace(String)
    case missingValue(String)
    case invalidSandbox(String)
    case unknownArgument(String)
    case qrCode(String)

    var errorDescription: String? {
        switch self {
        case .missingWorkspace: "缺少 --workspace <目录>"
        case .invalidWorkspace(let path): "工作目录不存在或不是文件夹：\(path)"
        case .missingValue(let option): "\(option) 缺少参数值"
        case .invalidSandbox(let value): "不支持的 sandbox：\(value)"
        case .unknownArgument(let value): "无法识别的参数：\(value)"
        case .qrCode(let detail): detail
        }
    }
}

private struct Options {
    var workspace: URL?
    var codexExecutable: URL?
    var stateDirectory: URL?
    var model: String?
    var effort: String?
    var sandbox: CodexSandbox = .workspaceWrite
    var noOpenQRCode = false
    var logout = false
    var showHelp = false

    init(arguments: [String]) throws {
        var index = 0
        func value(for option: String) throws -> String {
            let next = index + 1
            guard arguments.indices.contains(next) else {
                throw CLIError.missingValue(option)
            }
            index = next
            return arguments[next]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--workspace", "-w":
                workspace = URL(fileURLWithPath: try value(for: argument))
            case "--codex":
                codexExecutable = URL(fileURLWithPath: try value(for: argument))
            case "--state-dir":
                stateDirectory = URL(fileURLWithPath: try value(for: argument))
            case "--model":
                model = try value(for: argument)
            case "--effort":
                effort = try value(for: argument)
            case "--sandbox":
                let raw = try value(for: argument)
                guard let parsed = CodexSandbox(rawValue: raw) else {
                    throw CLIError.invalidSandbox(raw)
                }
                sandbox = parsed
            case "--no-open-qr": noOpenQRCode = true
            case "--logout": logout = true
            case "--help", "-h": showHelp = true
            default: throw CLIError.unknownArgument(argument)
            }
            index += 1
        }
    }

    static let help = """
    微信对接 Codex 的最小独立工具

    用法：
      swift run wechat-codex --workspace <目录> [选项]
      swift run wechat-codex --logout

    选项：
      -w, --workspace <目录>       Codex 的 cwd 和默认可写根
      --codex <路径>              指定 codex 可执行文件
      --model <模型>              可选；不传则使用 Codex 默认模型
      --effort <强度>             可选；传给 Codex reasoning effort
      --sandbox <模式>            read-only | workspace-write | danger-full-access
      --state-dir <目录>          覆盖本地状态目录
      --no-open-qr                只生成二维码文件，不自动打开
      --logout                    清除 Keychain 凭据和本地状态
      -h, --help                  显示帮助
    """
}

private enum QRCodeWriter {
    static func write(content: String, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        ) else { throw CLIError.qrCode("无法生成微信二维码") }
        let context = CIContext()
        guard let data = context.pngRepresentation(
            of: output,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else { throw CLIError.qrCode("无法编码微信二维码") }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }
}
