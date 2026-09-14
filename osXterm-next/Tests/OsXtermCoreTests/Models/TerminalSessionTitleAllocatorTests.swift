import Testing
@testable import OsXtermCore

struct TerminalSessionTitleAllocatorTests {
    @Test
    func keepsTheBaseTitleForTheFirstSession() {
        #expect(TerminalSessionTitleAllocator.nextTitle(
            base: "Production",
            existingTitles: ["Staging"]
        ) == "Production")
    }

    @Test
    func usesTheFirstAvailableOrdinalForConcurrentSessions() {
        #expect(TerminalSessionTitleAllocator.nextTitle(
            base: "Production",
            existingTitles: ["Production", "Production (2)", "Production (4)"]
        ) == "Production (3)")
    }

    @Test
    func ignoresWhitespaceWhenCheckingExistingTitles() {
        #expect(TerminalSessionTitleAllocator.nextTitle(
            base: " Production ",
            existingTitles: [" Production "]
        ) == "Production (2)")
    }
}
