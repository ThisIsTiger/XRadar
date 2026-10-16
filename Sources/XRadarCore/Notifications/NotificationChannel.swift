// NotificationChannel.swift
import Foundation

public protocol NotificationChannel: Sendable {
    var id: NotificationChannelID { get }
    func send(_ event: NotificationEvent) async -> DeliveryResult
    func sendTest() async -> DeliveryResult
}
