// WakeObserver.swift
import Foundation
import AppKit

public final class WakeObserver: NSObject {
    private let onWake: () -> Void

    public init(onWake: @escaping () -> Void) {
        self.onWake = onWake
        super.init()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleWake() {
        onWake()
    }
}
