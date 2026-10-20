import Testing
@testable import MacPilot

struct LocalNetworkSessionDiagnosisTests {
    @Test func anotherConsoleAccountOwnsTheLocalNetworkDecision() {
        #expect(
            LocalNetworkSessionDiagnosis.otherConsoleUser(
                consoleUser: "agentuse",
                processUser: "guofeng"
            ) == "agentuse"
        )
        #expect(
            LocalNetworkSessionDiagnosis.otherConsoleUser(
                consoleUser: "guofeng",
                processUser: "guofeng"
            ) == nil
        )
        #expect(
            LocalNetworkSessionDiagnosis.otherConsoleUser(
                consoleUser: nil,
                processUser: "guofeng"
            ) == nil
        )
        #expect(
            LocalNetworkSessionDiagnosis.otherConsoleUser(
                consoleUser: "",
                processUser: "guofeng"
            ) == nil
        )
    }

    @Test func consoleMismatchHintNamesBothAccountsInBothLanguages() {
        let chinese = AppText.value(
            "remoteNetworkOtherConsoleUserHint",
            language: .simplifiedChinese,
            arguments: ["agentuse", "guofeng"]
        )
        #expect(chinese.contains("agentuse"))
        #expect(chinese.contains("guofeng"))
        #expect(!chinese.contains("%"))

        let english = AppText.value(
            "remoteNetworkOtherConsoleUserHint",
            language: .english,
            arguments: ["agentuse", "guofeng"]
        )
        #expect(english.contains("agentuse"))
        #expect(english.contains("guofeng"))
        #expect(!english.contains("%"))
    }
}
