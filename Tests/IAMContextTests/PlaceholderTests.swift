import Testing

@Suite
struct IAMContextPlaceholderTests {
    // Anti-test-theater (Phase 1.s / D6): a placeholder must NOT report green.
    // .disabled => reports as skipped; Issue.record => fails (not false-green) if .disabled is removed before a real test is authored.
    @Test(.disabled("Placeholder — no tests yet. Run /test-gen against a bundle-plan task spec, then author the Given fixtures."))
    func placeholder() {
        Issue.record("pending: IAMContext has no authored tests yet")
    }
}
