import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
struct NeteaseSignInView: View {
    let audio: CommuteAudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = UUID()
    @State private var codeImage: UIImage?
    @State private var message = "正在生成二维码"
    @State private var canRetry = false

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
                    Text("请用另一台设备的网易云音乐扫一扫，并在扫码设备上确认登录。")
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
            .task(id: attempt) { await signIn() }
        }
    }

    private func signIn() async {
        codeImage = nil
        canRetry = false
        message = "正在生成二维码"
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
            let deadline = Date.now.addingTimeInterval(180)
            while Date.now < deadline {
                try await Task.sleep(for: .seconds(3))
                let status = try await NeteaseAudioCatalog.checkSignIn(challenge)
                try Task.checkCancellation()
                switch status {
                case .waiting: continue
                case .scanned: message = "已扫码，请在扫码设备上确认"
                case .expired:
                    allowRetry("二维码已过期。")
                    return
                case .authorized(let cookie):
                    try audio.authorizeNetease(cookie)
                    dismiss()
                    return
                }
            }
            allowRetry("二维码已过期。")
        } catch {
            guard !Task.isCancelled else { return }
            allowRetry("登录暂时无法完成，请检查网络并重试。")
        }
    }

    private func allowRetry(_ text: String) {
        codeImage = nil
        message = text
        canRetry = true
    }
}
