// KeywordNormalizer.swift
import Foundation

enum KeywordNormalizer {
    static func normalize(_ text: String, caseSensitive: Bool) -> String {
        var result = text

        // Unicode Canonical Normalization (NFC)
        result = result.precomposedStringWithCanonicalMapping

        if !caseSensitive {
            // Case folding
            result = result.lowercased()
        }

        // Width insensitive (fullwidth to halfwidth)
        result = result.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? result

        // Diacritic insensitive
        result = result.folding(options: .diacriticInsensitive, locale: .current)

        return result
    }
}
