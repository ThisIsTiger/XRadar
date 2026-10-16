// XSession.swift
import Foundation
import WebKit

@MainActor
public protocol XSessionProtocol: AnyObject, Sendable {
    var state: XSessionState { get }
    func presentLogin() async
    func validateSession() async -> XSessionState
    func makeAuthenticatedWebView() -> WKWebView
    func logout() async throws
}

@MainActor
public final class XSession: NSObject, XSessionProtocol, ObservableObject {
    @Published public private(set) var state: XSessionState = .unknown

    private let websiteDataStore = WKWebsiteDataStore.default()
    private var loginWindow: NSWindow?
    private var probeWebView: WKWebView?
    private var lastValidationAt: Date?
    private let validationCacheDuration: TimeInterval = 300

    public var currentState: XSessionState { state }

    public override init() {
        super.init()
    }

    public func presentLogin() async {
        let config = makeConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        let loginVC = LoginViewController(webView: webView)
        let window = NSWindow(contentViewController: loginVC)
        window.title = "登录 X"
        window.setContentSize(NSSize(width: 800, height: 600))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.makeKeyAndOrderFront(nil)

        self.loginWindow = window

        // Load login page
        if let url = URL(string: "https://x.com/i/flow/login") {
            webView.load(URLRequest(url: url))
        }

        // Wait for window to close
        await withCheckedContinuation { continuation in
            loginVC.onClose = {
                continuation.resume()
            }
        }

        // After login window closes, wait a moment for cookies to be saved
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Validate after login
        _ = await validateSession()
    }

    public func validateSession() async -> XSessionState {
        if state.isLoggedIn,
           let lastValidationAt,
           Date().timeIntervalSince(lastValidationAt) < validationCacheDuration {
            return state
        }
        state = .validating
        let hasAuthenticationCookie = await self.hasPersistentAuthenticationCookie()

        let config = makeConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        self.probeWebView = webView

        return await withCheckedContinuation { continuation in
            let delegate = ProbeNavigationDelegate(
                hasAuthenticationCookie: hasAuthenticationCookie
            ) { [weak self] result in
                defer { self?.probeWebView = nil }

                self?.state = result
                if result.isLoggedIn {
                    self?.lastValidationAt = Date()
                }
                continuation.resume(returning: result)
            }
            objc_setAssociatedObject(webView, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = delegate

            // Navigate to a page that requires login
            if let url = URL(string: "https://x.com/home") {
                webView.load(URLRequest(url: url))
            }

            // 15 second timeout. Use a strong reference to the delegate so the
            // continuation is always resumed even if the webView is released.
            // ProbeNavigationDelegate.finish() is idempotent (guarded by
            // isCompleted), so a double-fire is harmless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [delegate] in
                delegate.finish(
                    hasAuthenticationCookie
                        ? .loggedIn(handle: nil)
                        : .failed(message: "验证超时")
                )
            }
        }
    }

    private func hasPersistentAuthenticationCookie() async -> Bool {
        await withCheckedContinuation { continuation in
            self.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let hasAuthenticationCookie = Self.hasValidAuthenticationCookie(in: cookies)
                continuation.resume(returning: hasAuthenticationCookie)
            }
        }
    }

    nonisolated static func hasValidAuthenticationCookie(in cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            let domain = cookie.domain.lowercased()
            let belongsToX = domain == "x.com" ||
                domain.hasSuffix(".x.com") ||
                domain == "twitter.com" ||
                domain.hasSuffix(".twitter.com")
            let isUnexpired = cookie.expiresDate.map { $0 > Date() } ?? true
            return belongsToX &&
                cookie.name == "auth_token" &&
                isUnexpired
        }
    }


    public func logout() async throws {
        // Clear all WebKit data
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)
        await websiteDataStore.removeData(ofTypes: dataTypes, modifiedSince: date)

        state = .loggedOut
        lastValidationAt = nil
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore
        // Always enable inspection so the offscreen scraping WebView can be
        // examined via Safari > Develop > {Mac} > XRadar
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        return config
    }

    public func makeAuthenticatedWebView() -> WKWebView {
        let wv = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900),
            configuration: makeConfiguration()
        )
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        return wv
    }
}

extension XSession: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Allow HTTPS only
        if let url = navigationAction.request.url {
            if url.scheme == "https" {
                decisionHandler(.allow)
                return
            } else if url.scheme == "http" {
                // Upgrade HTTP to HTTPS for x.com
                if let host = url.host, host.contains("x.com") || host.contains("twitter.com") {
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    components?.scheme = "https"
                    if let httpsURL = components?.url {
                        webView.load(URLRequest(url: httpsURL))
                        decisionHandler(.cancel)
                        return
                    }
                }
            }
        }
        decisionHandler(.allow)
    }
}

// MARK: - Probe Navigation Delegate

private class ProbeNavigationDelegate: NSObject, WKNavigationDelegate {
    let completion: (XSessionState) -> Void
    let hasAuthenticationCookie: Bool
    private var isCompleted = false
    private var hasStartedInspection = false

    init(
        hasAuthenticationCookie: Bool,
        completion: @escaping (XSessionState) -> Void
    ) {
        self.hasAuthenticationCookie = hasAuthenticationCookie
        self.completion = completion
    }

    /// Thread-safe guard: only the first call resumes the continuation.
    func finish(_ state: XSessionState) {
        guard !isCompleted else { return }
        isCompleted = true
        completion(state)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isCompleted else { return }
        let url = webView.url?.absoluteString ?? ""

        // Check if redirected to login
        if url.contains("/login") || url.contains("/flow/login") {
            finish(.loggedOut)
            return
        }

        // Check for challenge/account access
        if url.contains("/challenge") || url.contains("/account/access") {
            finish(.actionRequired(message: "X 需要额外验证"))
            return
        }

        // Check if on home or profile page. X is a client-rendered app, so the
        // profile link may appear several seconds after didFinish.
        if url.contains("/home") || url.contains("x.com/") {
            guard !self.hasStartedInspection else { return }
            self.hasStartedInspection = true
            self.inspectAuthenticatedPage(webView, attemptsRemaining: 12)
        }
    }

    private func inspectAuthenticatedPage(_ webView: WKWebView, attemptsRemaining: Int) {
        guard !self.isCompleted else { return }

        let url = webView.url?.absoluteString ?? ""
        if url.contains("/login") || url.contains("/flow/login") {
            self.finish(.loggedOut)
            return
        }
        if url.contains("/challenge") || url.contains("/account/access") {
            self.finish(.actionRequired(message: "X 需要额外验证"))
            return
        }

        webView.evaluateJavaScript(XDOMSelectors.profileLinkScript) { [weak self, weak webView] result, error in
            guard let self = self, !self.isCompleted else { return }
            if let handle = result as? String, !handle.isEmpty {
                self.finish(.loggedIn(handle: handle))
                return
            }

            guard attemptsRemaining > 1, error == nil, let webView = webView else {
                if self.hasAuthenticationCookie {
                    self.finish(.loggedIn(handle: nil))
                } else if error != nil {
                    self.finish(.failed(message: "无法确认 X 登录状态"))
                } else {
                    self.finish(.loggedOut)
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak webView] in
                guard let self = self, let webView = webView else { return }
                self.inspectAuthenticatedPage(webView, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failed(message: error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failed(message: error.localizedDescription))
    }
}
