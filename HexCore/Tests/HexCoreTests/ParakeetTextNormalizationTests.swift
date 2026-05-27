import Foundation
import Testing
@testable import HexCore

struct ParakeetTextNormalizationTests {
    @Test func chunkArtifactCleanerRemovesLowercaseMidWordPeriodsOnly() {
        let text = "The t.ier m.erge code returned a use.less result."

        #expect(ParakeetTextNormalization.cleanChunkBoundaryArtifacts(text) == "The tier merge code returned a useless result.")
    }

    @Test func chunkArtifactCleanerDoesNotRewriteAbbreviationLikeUppercaseBoundaries() {
        let text = "Use U.S.a routing, E.U.rules, X.y test labels, and API.v2 as written."

        #expect(ParakeetTextNormalization.cleanChunkBoundaryArtifacts(text) == text)
    }

    @Test func chunkArtifactCleanerPreservesSentenceAndDecimalPunctuation() {
        let text = "Stop. go now. Version 1.2 stayed stable."

        #expect(ParakeetTextNormalization.cleanChunkBoundaryArtifacts(text) == text)
    }

    @Test func comparisonNormalizerIgnoresCasePunctuationAndDiacritics() {
        let direct = "Résumé: FIX the Parakeet path, now."
        let file = "resume fix the parakeet path now"

        #expect(
            ParakeetTextNormalization.normalizedComparisonText(direct, locale: Locale(identifier: "en_US_POSIX"))
                == ParakeetTextNormalization.normalizedComparisonText(file, locale: Locale(identifier: "en_US_POSIX"))
        )
    }

    @Test func comparisonNormalizerDoesNotCollapseDifferentNumbers() {
        let direct = "finished in 189 ms"
        let file = "finished in 198 ms"

        #expect(
            ParakeetTextNormalization.normalizedComparisonText(direct, locale: Locale(identifier: "en_US_POSIX"))
                != ParakeetTextNormalization.normalizedComparisonText(file, locale: Locale(identifier: "en_US_POSIX"))
        )
    }
}
