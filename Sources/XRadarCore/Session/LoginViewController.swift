// LoginViewController.swift
import Cocoa
import WebKit

class LoginViewController: NSViewController {
    private let webView: WKWebView
    var onClose: (() -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Address bar showing current host
        let addressBar = NSTextField()
        addressBar.translatesAutoresizingMaskIntoConstraints = false
        addressBar.isEditable = false
        addressBar.isBordered = true
        addressBar.backgroundColor = .controlBackgroundColor
        addressBar.alignment = .center
        addressBar.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        addressBar.tag = 100 // For lookup

        // WebView
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)

        container.addSubview(addressBar)
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            addressBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            addressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            addressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            addressBar.heightAnchor.constraint(equalToConstant: 28),

            webView.topAnchor.constraint(equalTo: addressBar.bottomAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.view = container
        updateAddressBar()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "URL" {
            Task { @MainActor in
                self.updateAddressBar()
            }
        }
    }

    private func updateAddressBar() {
        guard let addressBar = view.viewWithTag(100) as? NSTextField else { return }
        if let host = webView.url?.host {
            addressBar.stringValue = "🔒 \(host)"
        } else {
            addressBar.stringValue = ""
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        webView.removeObserver(self, forKeyPath: "URL")
        onClose?()
    }
}
