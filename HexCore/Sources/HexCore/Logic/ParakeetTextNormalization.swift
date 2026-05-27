import Foundation

public enum ParakeetTextNormalization {
    /// Removes FluidAudio chunk merge artifacts like `t.ier` without rewriting
    /// abbreviation-like uppercase boundaries such as `U.S.a`.
    public static func cleanChunkBoundaryArtifacts(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(\p{Ll})\.(\p{Ll})"#) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1$2")
    }

    public static func normalizedComparisonText(_ text: String, locale: Locale = .current) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
