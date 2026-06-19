import XCTest
@testable import CodeIslandCore

/// Context-window resolution for the `% ctx` chip (#5 follow-up). Covers the embedded-window
/// hint parser (so preview slugs like "orange_o48[1m]" get a %) and the Codex
/// `model_context_window` override path.
final class ContextWindowTests: XCTestCase {

    func testEmbeddedWindowHintParsesBracketedMillion() {
        XCTAssertEqual(SessionSnapshot.contextWindowLimit(forModel: "orange_o48[1m]"), 1_000_000)
    }

    func testEmbeddedWindowHintParsesKiloSuffix() {
        XCTAssertEqual(SessionSnapshot.contextWindowLimit(forModel: "some-preview-256k"), 256_000)
    }

    func testKnownFamiliesUnaffectedByHintParser() {
        XCTAssertEqual(SessionSnapshot.contextWindowLimit(forModel: "claude-opus-4-1-20250805"), 200_000)
        XCTAssertEqual(SessionSnapshot.contextWindowLimit(forModel: "gpt-4o"), 128_000)
        XCTAssertEqual(SessionSnapshot.contextWindowLimit(forModel: "gemini-2.5-pro"), 1_000_000)
    }

    func testNoHintReturnsNil() {
        XCTAssertNil(SessionSnapshot.contextWindowLimit(forModel: "orange_o48"))
        XCTAssertNil(SessionSnapshot.contextWindowLimit(forModel: "mystery-model"))
        // A tiny "<8k" number must not be mistaken for a window.
        XCTAssertNil(SessionSnapshot.contextWindowLimit(forModel: "weird-4k-thing"))
    }

    func testContextWindowPercentUsesEmbeddedHint() {
        var s = SessionSnapshot()
        s.model = "orange_o48[1m]"
        s.lastInputTokens = 510_000
        XCTAssertEqual(s.contextWindowPercent, 51)   // 510k / 1M
    }

    func testCodexOverrideTakesPrecedenceForPercent() {
        var s = SessionSnapshot()
        s.model = "orange_o48"            // unknown to the name-based guesser
        s.contextWindowOverride = 258_400 // exact window from Codex's model_context_window
        s.lastInputTokens = 35_419
        s.lastCacheReadTokens = 22_912    // contextTokensUsed == 58_331
        XCTAssertEqual(s.contextWindowPercent, 22)   // 58331 / 258400
    }
}
