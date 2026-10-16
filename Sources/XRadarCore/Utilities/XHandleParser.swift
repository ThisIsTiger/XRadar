// XHandleParser.swift
import Foundation

public enum XHandleParser {
    static let reservedPaths: Set<String> = [
        "home", "explore", "notifications", "messages", "i",
        "search", "settings", "compose", "login", "logout"
    ]

    public static func parse(_ input: String) throws -> String {
        var input = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle @ prefix
        if input.hasPrefix("@") {
            input = String(input.dropFirst())
        }

        // Handle URLs
        if let url = URL(string: input),
           let host = url.host?.lowercased(),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {

            let validHosts = ["x.com", "www.x.com", "twitter.com", "www.twitter.com"]
            guard validHosts.contains(host) else {
                throw AppError.invalidHandle
            }

            // Get first path component
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let pathComponents = path.split(separator: "/").map(String.init)

            guard let firstComponent = pathComponents.first, !firstComponent.isEmpty else {
                throw AppError.invalidHandle
            }

            input = firstComponent
        }

        // Validate handle format
        let handle = input.lowercased()

        // Check reserved paths
        guard !reservedPaths.contains(handle) else {
            throw AppError.invalidHandle
        }

        // Validate characters: [A-Za-z0-9_], length 1-15
        let validCharacters = CharacterSet(charactersIn: "_").union(.alphanumerics)
        guard handle.unicodeScalars.allSatisfy({ validCharacters.contains($0) }),
              handle.count >= 1,
              handle.count <= 15 else {
            throw AppError.invalidHandle
        }

        return handle
    }
}
