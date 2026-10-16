// WebViewTimelineProvider.swift
import Foundation
import WebKit

public final class WebViewTimelineProvider: TimelineProvider, @unchecked Sendable {
    public let id: TimelineProviderID = .xWeb
    private let xSession: XSession
    @MainActor private var activeWebViews: [UUID: WKWebView] = [:]
    @MainActor private var activeHostWindows: [UUID: NSWindow] = [:]
    @MainActor private var reusableHostWindows: [NSWindow] = []
    /// Maximum number of pooled offscreen windows to retain between runs.
    private static let maxPooledWindows = 3

    public init(xSession: XSession) {
        self.xSession = xSession
    }

    public func fetch(_ request: TimelineRequest) async throws -> TimelineFetchResult {
        guard request.includeReplies else {
            guard let profileURL = URL(string: "https://x.com/\(request.accountHandle)") else {
                throw TimelineError.networkUnavailable
            }
            let tweets = try await self.fetchFromWebView(request, url: profileURL)
            return TimelineFetchResult(
                tweets: tweets,
                providerID: .xWeb,
                rawItemCount: tweets.count,
                feedState: .healthy
            )
        }

        guard let repliesURL = URL(string: "https://x.com/\(request.accountHandle)/with_replies"),
              let profileURL = URL(string: "https://x.com/\(request.accountHandle)") else {
            throw TimelineError.networkUnavailable
        }

        // Use the account's browser timeline as the primary source. Loading
        // search + profile + replies in one poll looks like automation and can
        // trigger X risk controls. Only fall back to the normal profile page
        // after a slow, page-level failure; never retry a rate-limit/challenge.
        let primary = await self.fetchSource(request, url: repliesURL)
        if !primary.tweets.isEmpty || primary.error == nil {
            let tweets = Array(Self.sortedNewestFirst(primary.tweets).prefix(request.maximumCount))
            return TimelineFetchResult(
                tweets: tweets,
                providerID: .xWeb,
                rawItemCount: tweets.count,
                feedState: .healthy
            )
        }

        if let error = primary.error,
           !Self.canUseProfileFallback(for: error) {
            throw error
        }

        try? await Task.sleep(for: .seconds(8))
        let fallback = await self.fetchSource(request, url: profileURL)
        if !fallback.tweets.isEmpty || fallback.error == nil {
            let tweets = Array(Self.sortedNewestFirst(fallback.tweets).prefix(request.maximumCount))
            return TimelineFetchResult(
                tweets: tweets,
                providerID: .xWeb,
                rawItemCount: tweets.count,
                feedState: .healthy
            )
        }
        throw Self.preferredError([primary.error, fallback.error].compactMap { $0 })
    }

    private func fetchSource(
        _ request: TimelineRequest,
        url: URL
    ) async -> (tweets: [Tweet], error: Error?) {
        do { return (try await self.fetchFromWebView(request, url: url), nil) }
        catch { return ([], error) }
    }

    private static func canUseProfileFallback(for error: Error) -> Bool {
        guard let timelineError = error as? TimelineError else { return true }
        switch timelineError {
        case .authenticationRequired, .userActionRequired, .rateLimited:
            return false
        case .pageLoadTimeout, .pageStructureChanged, .networkUnavailable:
            return true
        }
    }

    private static func preferredError(_ errors: [Error]) -> Error {
        for error in errors {
            guard let timelineError = error as? TimelineError else { continue }
            switch timelineError {
            case .authenticationRequired, .userActionRequired, .rateLimited:
                return timelineError
            default:
                continue
            }
        }
        return errors.first ?? TimelineError.pageStructureChanged
    }

    private func fetchFromWebView(_ request: TimelineRequest, url: URL) async throws -> [Tweet] {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let identifier = UUID()
                let webView = self.xSession.makeAuthenticatedWebView()
                let hostWindow = self.acquireHostWindow(for: webView)
                self.activeWebViews[identifier] = webView
                self.activeHostWindows[identifier] = hostWindow

                let delegate = TimelineNavigationDelegate(
                    request: request,
                    continuation: continuation,
                    cleanup: { [weak self, weak webView] in
                        guard let self = self else { return }
                        Task { @MainActor in
                            if let webView = webView {
                                objc_setAssociatedObject(webView, "timelineDelegate", nil, .OBJC_ASSOCIATION_RETAIN)
                                webView.stopLoading()
                            }
                            self.activeWebViews.removeValue(forKey: identifier)
                            if let hostWindow = self.activeHostWindows.removeValue(forKey: identifier) {
                                // Do not close/order-out the window here. AppKit
                                // can retain a transform animation past cleanup,
                                // causing a use-after-free. Keep a tiny pool of
                                // offscreen windows and reuse them next run.
                                hostWindow.contentView = NSView(frame: hostWindow.contentLayoutRect)
                                if self.reusableHostWindows.count < Self.maxPooledWindows {
                                    self.reusableHostWindows.append(hostWindow)
                                } else {
                                    hostWindow.close()
                                }
                            }
                        }
                    }
                )
                objc_setAssociatedObject(webView, "timelineDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
                webView.navigationDelegate = delegate
                // Start checking 1.5 seconds after load even if WebKit didFinish hasn't fired
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak delegate, weak webView] in
                    guard let webView = webView else { return }
                    delegate?.startCheckingIfNeeded(in: webView)
                }

                // Overall safety timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak delegate] in
                    delegate?.timeout()
                }

                webView.load(URLRequest(url: url))
            }
        }
    }

    @MainActor
    private func acquireHostWindow(for webView: WKWebView) -> NSWindow {
        let window: NSWindow
        if let reusable = self.reusableHostWindows.popLast() {
            window = reusable
        } else {
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 1_200, height: 900),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
            window.level = .normal
            window.alphaValue = 0  // invisible but not suppressed by the compositor
        }
        webView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 900)
        window.contentView = webView
        // orderFrontRegardless prevents macOS 26+ WebKit from throttling JS in
        // windows it considers "background". The window is invisible (alpha=0)
        // and positioned far off every display, so users never see it.
        window.orderFrontRegardless()
        return window
    }

    static func filteredTweets(
        from records: [RawTweetDOMRecord],
        request: TimelineRequest
    ) -> [Tweet] {
        let requestedHandle = request.accountHandle.lowercased()
        var seenTweetIDs: Set<String> = []

        let matchingTweets = records.compactMap { record -> Tweet? in
            guard let tweet = record.toTweet() else { return nil }
            if let earliestPublishedAt = request.earliestPublishedAt {
                guard let publishedAt = tweet.publishedAt,
                      publishedAt >= earliestPublishedAt else {
                    return nil
                }
            }
            let isTargetAuthored = tweet.authorHandle.lowercased() == requestedHandle
            let isTargetRepost = request.includeReposts && tweet.kind == .repost
            guard isTargetAuthored || isTargetRepost else {
                return nil
            }
            guard seenTweetIDs.insert(tweet.id).inserted else {
                return nil
            }
            return Tweet(
                id: tweet.id,
                authorHandle: isTargetRepost ? request.accountHandle : tweet.authorHandle,
                text: tweet.text,
                url: tweet.url,
                publishedAt: tweet.publishedAt,
                kind: tweet.kind,
                isPinned: tweet.isPinned
            )
        }
        let recentTweets = Array(
            Self.sortedNewestFirst(matchingTweets)
                .prefix(request.maximumCount)
        )
        return recentTweets.filter { !request.excludedTweetIDs.contains($0.id) }
    }

    static func sortedNewestFirst(_ tweets: [Tweet]) -> [Tweet] {
        tweets.sorted { lhs, rhs in
            if let lhsDate = lhs.publishedAt, let rhsDate = rhs.publishedAt,
               lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            let lhsID = UInt64(lhs.id) ?? 0
            let rhsID = UInt64(rhs.id) ?? 0
            if lhsID != rhsID {
                return lhsID > rhsID
            }
            return lhs.id > rhs.id
        }
    }
}

// MARK: - Navigation Delegate

private class TimelineNavigationDelegate: NSObject, WKNavigationDelegate {
    let request: TimelineRequest
    let continuation: CheckedContinuation<[Tweet], Error>
    let cleanup: (() -> Void)?
    var checkCount = 0
    var maxChecks = 120 // 60 seconds (500ms intervals) - X takes longer to load
    var isCompleted = false
    var hasStartedChecking = false
    var accumulatedRecords: [String: RawTweetDOMRecord] = [:]
    var extractionPass = 0
    let maximumExtractionPasses = 8

    init(request: TimelineRequest, continuation: CheckedContinuation<[Tweet], Error>, cleanup: (() -> Void)? = nil) {
        self.request = request
        self.continuation = continuation
        self.cleanup = cleanup
    }

    func timeout() {
        guard !isCompleted else { return }
        isCompleted = true
        cleanup?()
        continuation.resume(throwing: TimelineError.pageLoadTimeout)
    }

    func startCheckingIfNeeded(in webView: WKWebView) {
        guard !isCompleted else { return }
        let url = webView.url?.absoluteString ?? ""

        // Check for login redirect
        if url.contains("/login") {
            isCompleted = true
            cleanup?()
            continuation.resume(throwing: TimelineError.authenticationRequired)
            return
        }

        // Check for challenge
        if url.contains("/challenge") || url.contains("/account/access") {
            isCompleted = true
            cleanup?()
            continuation.resume(throwing: TimelineError.userActionRequired("X 需要额外验证"))
            return
        }

        guard !hasStartedChecking else { return }
        hasStartedChecking = true
        checkForTweets(in: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        startCheckingIfNeeded(in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        startCheckingIfNeeded(in: webView)
    }

    func checkForTweets(in webView: WKWebView) {
        guard !isCompleted else { return }
        guard checkCount < maxChecks else {
            isCompleted = true
            cleanup?()
            continuation.resume(throwing: TimelineError.pageStructureChanged)
            return
        }

        checkCount += 1

        let inspectScript = """
        (function() {
            if (document.querySelector('a[href*="/login"], a[href*="/flow/login"], div[data-testid="loginButton"]')) {
                return { status: 'login_required' };
            }
            // Detect X.com error screens (often shown on 429 Rate Limit or API failures)
            var errorDetail = document.querySelector('[data-testid="error-detail"]');
            var emptyState = document.querySelector('[data-testid="emptyState"]');
            var textContent = document.body ? document.body.innerText.toLowerCase() : '';
            if (errorDetail || textContent.includes('rate limit exceeded') || textContent.includes('something went wrong. try reloading')) {
                return { status: 'rate_limited' };
            }

            var articles = document.querySelectorAll('article').length;
            var links = document.querySelectorAll('a[href*="status"]').length;
            var isReady = document.readyState === 'complete';
            return { status: 'ok', articles: articles, links: links, ready: isReady };
        })();
        """

        webView.evaluateJavaScript(inspectScript) { [weak self] result, error in
            guard let self = self, !self.isCompleted else { return }

            if let dict = result as? [String: Any], let status = dict["status"] as? String {
                if status == "login_required" {
                    self.isCompleted = true
                    self.cleanup?()
                    self.continuation.resume(throwing: TimelineError.authenticationRequired)
                    return
                }

                if status == "rate_limited" {
                    self.isCompleted = true
                    self.cleanup?()
                    self.continuation.resume(throwing: TimelineError.rateLimited(retryAfter: nil))
                    return
                }

                let articles = dict["articles"] as? Int ?? 0
                let links = dict["links"] as? Int ?? 0
                let isReady = dict["ready"] as? Bool ?? false

                if articles > 0 && links > 0 {
                    // Trigger a scroll to force X's virtual list to render before extracting
                    webView.evaluateJavaScript("window.scrollTo(0, 200);") { _, _ in }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self else { return }
                        self.performExtraction(from: webView)
                    }
                    return
                }

                if articles > 0 && self.checkCount >= 5 {
                    webView.evaluateJavaScript("window.scrollTo(0, 200);") { _, _ in }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self else { return }
                        self.performExtraction(from: webView)
                    }
                    return
                }
                // If page is ready but has no articles after 30s, give up cleanly.
                // (30s = 60 checks × 500ms)
                if isReady && self.checkCount >= 60 {
                    self.isCompleted = true
                    self.cleanup?()
                    self.continuation.resume(throwing: TimelineError.pageStructureChanged)
                    return
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.checkForTweets(in: webView)
            }
        }
    }

    private func performExtraction(from webView: WKWebView) {
        guard !isCompleted else { return }
        let script = XDOMSelectors.tweetExtractionScript(maxTweets: request.maximumCount)

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self = self, !self.isCompleted else { return }

            if let jsonString = result as? String,
               let data = jsonString.data(using: .utf8) {
                do {
                    let records = try JSONDecoder().decode([RawTweetDOMRecord].self, from: data)
                    for record in records {
                        self.accumulatedRecords[record.id] = record
                    }
                    self.extractionPass += 1
                    let filteredCount = WebViewTimelineProvider.filteredTweets(
                        from: Array(self.accumulatedRecords.values),
                        request: self.request
                    ).count
                    let shouldFinish =
                        filteredCount >= self.request.maximumCount ||
                        self.extractionPass >= self.maximumExtractionPasses

                    if shouldFinish {
                        self.finishExtraction()
                        return
                    }

                    webView.evaluateJavaScript(
                        """
                        (() => {
                            const scroller = document.scrollingElement || document.documentElement;
                            const step = Math.max(450, Math.floor(window.innerHeight * 0.8));
                            scroller.scrollTop = Math.min(scroller.scrollTop + step, scroller.scrollHeight);
                            window.dispatchEvent(new Event('scroll'));
                            return {
                                top: scroller.scrollTop,
                                height: scroller.scrollHeight,
                                viewport: window.innerHeight
                            };
                        })();
                        """
                    ) { [weak self, weak webView] _, _ in
                        let delay = Double.random(in: 1.2...2.2)
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard let self = self, let webView = webView else { return }
                            self.performExtraction(from: webView)
                        }
                    }
                } catch {
                    self.finishExtraction(error: .pageStructureChanged)
                }
            } else {
                self.finishExtraction(error: .pageStructureChanged)
            }
        }
    }

    private func finishExtraction(error: TimelineError? = nil) {
        guard !self.isCompleted else { return }
        self.isCompleted = true
        self.cleanup?()

        let tweets = WebViewTimelineProvider.filteredTweets(
            from: Array(self.accumulatedRecords.values),
            request: self.request
        )
        if !tweets.isEmpty {
            self.continuation.resume(returning: tweets)
        } else if let error {
            self.continuation.resume(throwing: error)
        } else {
            self.continuation.resume(returning: [])
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isCompleted else { return }
        isCompleted = true
        cleanup?()
        continuation.resume(throwing: TimelineError.networkUnavailable)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isCompleted else { return }
        isCompleted = true
        cleanup?()
        continuation.resume(throwing: TimelineError.networkUnavailable)
    }
}
