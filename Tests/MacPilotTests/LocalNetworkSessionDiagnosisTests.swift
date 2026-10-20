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

    @Test func consoleMismatchExplanationNamesBothAccountsInBothLanguages() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            let problem = AppText.value(
                "remoteNetworkOtherConsoleUserProblem",
                language: language,
                arguments: ["agentuse", "guofeng"]
            )
            let steps = AppText.value(
                "remoteNetworkOtherConsoleUserSteps",
                language: language,
                arguments: ["agentuse", "guofeng"]
            )
            for text in [problem, steps] {
                #expect(text.contains("agentuse"))
                #expect(text.contains("guofeng"))
                #expect(!text.contains("%"))
            }
        }
    }

    @Test func everyLocalNetworkStateExplainsProblemAndFixInBothLanguages() {
        let states = [
            ("remoteNetworkDeniedProblem", "remoteNetworkDeniedSteps"),
            ("remoteNetworkOtherConsoleUserProblem", "remoteNetworkOtherConsoleUserSteps"),
            ("remoteNetworkFailedProblem", "remoteNetworkFailedSteps"),
        ]
        for language in [AppLanguage.simplifiedChinese, .english] {
            let pairings = language == .simplifiedChinese
                ? "已有配对会保留"
                : "Existing pairings are kept"
            for (problemKey, stepsKey) in states {
                let problem = AppText.value(
                    problemKey,
                    language: language,
                    arguments: ["agentuse", "guofeng"]
                )
                let steps = AppText.value(
                    stepsKey,
                    language: language,
                    arguments: ["agentuse", "guofeng"]
                )
                #expect(!problem.isEmpty)
                #expect(problem != problemKey)
                #expect(!problem.contains("%"))
                #expect(!steps.isEmpty)
                #expect(steps != stepsKey)
                #expect(!steps.contains("%"))
                #expect(steps.contains(pairings))
            }

            let problemLine = AppText.value(
                "remoteNetworkNoticeProblemLine",
                language: language,
                arguments: ["detail"]
            )
            let stepsLine = AppText.value(
                "remoteNetworkNoticeStepsLine",
                language: language,
                arguments: ["detail"]
            )
            #expect(problemLine.contains("detail"))
            #expect(stepsLine.contains("detail"))
            #expect(!problemLine.contains("%"))
            #expect(!stepsLine.contains("%"))
        }

        #expect(
            AppText.value(
                "remoteNetworkNoticeProblemLine",
                language: .simplifiedChinese,
                arguments: ["原因"]
            ).contains("可能的问题")
        )
        #expect(
            AppText.value(
                "remoteNetworkNoticeStepsLine",
                language: .simplifiedChinese,
                arguments: ["步骤"]
            ).contains("处理方法")
        )
        #expect(
            AppText.value(
                "remoteNetworkNoticeProblemLine",
                language: .english,
                arguments: ["reason"]
            ).contains("Possible problem")
        )
        #expect(
            AppText.value(
                "remoteNetworkNoticeStepsLine",
                language: .english,
                arguments: ["step"]
            ).contains("How to fix")
        )
    }
}
