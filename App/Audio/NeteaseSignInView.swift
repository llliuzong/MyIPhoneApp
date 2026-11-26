import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
struct NeteaseSignInView: View {
    let audio: CommuteAudioPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var attempt = UUID()
    @State private var challenge: NeteaseAudioCatalog.SignIn?
    @State private var codeImage: UIImage?
    @State private var message = "正在生成二维码"
    @State private var canRetry = false
    @State private var scanned = false

    private enum Stage: String {
        case createCode = "生成二维码"
        case poll = "查询扫码状态"
        case verify = "验证网易云登录状态"
        case save = "保存登录状态"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let codeImage {
                    Image(uiImage: codeImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 210, height: 210)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("网易云登录二维码")
                    Text("用网易云音乐扫一扫。用同一台 iPhone 时，可截图后从扫一扫的相册入口选择二维码，确认后切回 LongWay。")
                        .multilineTextAlignment(.center)
                } else if !canRetry {
                    ProgressView()
                }
                Text(message).foregroundStyle(.secondary)
                if canRetry {
                    Button("获取新二维码") { attempt = UUID() }
                }
            }
            .padding(24)
            .navigationTitle("网易云登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .task(id: attempt) { await createCode() }
            .task(id: scenePhase == .active ? challenge?.key : nil) {
                if scenePhase == .active, let challenge { await poll(challenge) }
            }
        }
    }

    private func createCode() async {
        challenge = nil
        codeImage = nil
        canRetry = false
        scanned = false
        message = "正在生成二维码"
        audio.recordNeteaseSignIn("开始")
        do {
            let challenge = try await NeteaseAudioCatalog.startSignIn()
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(challenge.url.absoluteString.utf8)
            guard let output = filter.outputImage, let qr = CIContext().createCGImage(output, from: output.extent) else {
                throw NeteaseAudioCatalog.Failure.invalidResponse
            }
            try Task.checkCancellation()
            codeImage = UIImage(cgImage: qr)
            message = "等待扫码"
            self.challenge = challenge
            audio.recordNeteaseSignIn("二维码已生成")
        } catch {
            guard !Task.isCancelled else { return }
            fail(error, at: .createCode)
        }
    }

    private func poll(_ challenge: NeteaseAudioCatalog.SignIn) async {
        var stage = Stage.poll
        var transportFailures = 0
        do {
            while Date.now < challenge.expiresAt {
                try Task.checkCancellation()
                let status: NeteaseAudioCatalog.SignInStatus
                do {
                    status = try await NeteaseAudioCatalog.checkSignIn(challenge)
                    transportFailures = 0
                } catch let error as URLError where error.code != .cancelled {
                    try Task.checkCancellation()
                    transportFailures += 1
                    guard transportFailures < 3 else { throw error }
                    audio.recordNeteaseSignIn("查询暂时失败（网络 \(error.errorCode)），稍后重试")
                    try await Task.sleep(for: .seconds(3))
                    continue
                }
                try Task.checkCancellation()
                switch status {
                case .waiting: break
                case .scanned:
                    if !scanned {
                        scanned = true
                        message = "已扫码，请在网易云音乐确认"
                        audio.recordNeteaseSignIn("已扫码（802）")
                    }
                case .expired:
                    expireCode()
                    return
                case .authorized(let cookie):
                    audio.recordNeteaseSignIn("网易云已确认扫码（803）")
                    stage = .verify
                    try await NeteaseAudioCatalog.verifySignIn(cookie)
                    try Task.checkCancellation()
                    stage = .save
                    try audio.authorizeNetease(cookie)
                    dismiss()
                    return
                }
                try await Task.sleep(for: .seconds(3))
            }
            try Task.checkCancellation()
            expireCode()
        } catch {
            guard !Task.isCancelled else { return }
            fail(error, at: stage)
        }
    }

    private func expireCode() {
        audio.recordNeteaseSignIn("二维码已过期")
        allowRetry("二维码已过期。")
    }

    private func fail(_ error: Error, at stage: Stage) {
        let detail: String
        let text: String
        switch error {
        case NeteaseAudioCatalog.Failure.qrStatus(let code) where code == 8821 || code == 8830:
            detail = "网易云要求安全验证（\(code)）"
            text = "网易云安全校验拦截了这次登录（\(code)）。网易云提示更换登录方式或升级客户端。"
        case NeteaseAudioCatalog.Failure.qrStatus(let code):
            detail = "网易云返回 \(code)"
            text = "网易云返回登录错误（\(code)），请稍后重试。"
        case NeteaseAudioCatalog.Failure.missingSession:
            detail = "网易云确认扫码（803），未收到登录凭据"
            text = "网易云已确认扫码，但没有返回登录凭据。"
        case NeteaseAudioCatalog.Failure.accountRejected(let code):
            detail = "登录状态未通过账号验证（\(code.map { String($0) } ?? "无状态码")）"
            text = "网易云未确认账号登录状态，请重试。"
        case NeteaseAudioCatalog.Failure.keychain(let code):
            detail = "钥匙串错误 \(code)"
            text = "已登录网易云，但无法保存到此 iPhone 的钥匙串。"
        case NeteaseAudioCatalog.Failure.http(let status):
            detail = "HTTP \(status)"
            text = "网易云登录服务返回 HTTP \(status)，请稍后重试。"
        case let error as URLError:
            detail = "网络错误 \(error.errorCode)"
            text = "连接网易云登录服务失败，请检查网络并重试。"
        default:
            detail = "响应格式异常"
            text = "网易云登录服务响应异常，请稍后重试。"
        }
        audio.recordNeteaseSignIn("\(stage.rawValue)失败，\(detail)", failed: true)
        allowRetry(text)
    }

    private func allowRetry(_ text: String) {
        challenge = nil
        codeImage = nil
        message = text
        canRetry = true
    }
}
