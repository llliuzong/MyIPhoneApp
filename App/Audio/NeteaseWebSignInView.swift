import SwiftUI
import WebKit

@MainActor
struct NeteaseWebSignInView: View {
    let audio: CommuteAudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var websiteData = WKWebsiteDataStore.nonPersistent()
    @State private var pageAttempt = UUID()
    @State private var pageFailed = false
    @State private var failure: String?
    @State private var confirmation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if pageFailed {
                    VStack(spacing: 12) {
                        Text("暂时无法打开网易云登录页。")
                        Button("重新加载") {
                            pageAttempt = UUID()
                            pageFailed = false
                            failure = nil
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LoginPage(websiteData: websiteData, onFailure: { code in
                        pageFailed = true
                        audio.recordNeteaseSignIn("网页加载失败（\(code)）", failed: true, method: "网页")
                    })
                    .id(pageAttempt)
                }
                Divider()
                VStack(spacing: 10) {
                    Text(failure ?? "在网易云官网完成登录，再点下方按钮。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        confirmation = Task { await confirm() }
                    } label: {
                        if confirmation != nil {
                            ProgressView().accessibilityLabel("正在验证网易云登录")
                        } else {
                            Text("登录完成，读取红心歌曲")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pageFailed || confirmation != nil)
                }
                .padding()
            }
            .navigationTitle("网易云网页登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onAppear { audio.recordNeteaseSignIn("打开网易云官网", method: "网页") }
            .onDisappear { confirmation?.cancel() }
        }
    }

    private func confirm() async {
        defer { confirmation = nil }
        failure = nil
        let cookies = await websiteData.httpCookieStore.allCookies()
        guard !Task.isCancelled else { return }
        guard let cookie = NeteaseAudioCatalog.webSessionCookie(from: cookies) else {
            failure = "还没有收到网易云的登录状态。请在网页上完成登录后再试。"
            audio.recordNeteaseSignIn("网页尚未返回有效会话", failed: true, method: "网页")
            return
        }
        do {
            let count = try await NeteaseAudioCatalog.verifyWebSignIn(cookie)
            try Task.checkCancellation()
            audio.recordNeteaseSignIn("账号和红心歌曲访问已验证，共 \(count) 首", method: "网页")
            try audio.authorizeNetease(cookie)
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            switch error {
            case NeteaseAudioCatalog.Failure.keychain(let code):
                failure = "已验证网易云账号，但无法保存到此 iPhone 的钥匙串。"
                audio.recordNeteaseSignIn("钥匙串保存失败（\(code)）", failed: true, method: "网页")
            case NeteaseAudioCatalog.Failure.accountRejected(_), NeteaseAudioCatalog.Failure.signedOut:
                failure = "网易云未确认这个登录状态，请在网页上重新登录。"
                audio.recordNeteaseSignIn("网易云未接受网页登录会话", failed: true, method: "网页")
            default:
                failure = "暂时无法读取红心歌曲，请稍后重试。"
                audio.recordNeteaseSignIn("验证红心歌曲访问失败（\((error as NSError).code)）", failed: true, method: "网页")
            }
        }
    }
}

@MainActor
private struct LoginPage: UIViewRepresentable {
    let websiteData: WKWebsiteDataStore
    let onFailure: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteData
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: NeteaseAudioCatalog.webSignInURL, timeoutInterval: 25))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onFailure: (Int) -> Void

        init(onFailure: @escaping (Int) -> Void) {
            self.onFailure = onFailure
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isSubframe = navigationAction.targetFrame?.isMainFrame == false
            decisionHandler(isSubframe || isNeteasePage(navigationAction.request.url) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if isNeteasePage(navigationAction.request.url) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let failure = error as NSError
            guard failure.code != NSURLErrorCancelled, failure.code != 102 || failure.domain != "WebKitErrorDomain" else { return }
            onFailure(failure.code)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        }

        private func isNeteasePage(_ url: URL?) -> Bool {
            guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
            return host == "163.com" || host.hasSuffix(".163.com")
        }
    }
}
