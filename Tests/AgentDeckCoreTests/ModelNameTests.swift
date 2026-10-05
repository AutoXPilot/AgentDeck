import Testing
@testable import AgentDeckCore

struct ModelNameTests {
    @Test func claudeFamilies() {
        // ids observed live on this machine
        #expect(ModelName.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelName.display("claude-sonnet-5") == "Sonnet 5")
        #expect(ModelName.display("claude-haiku-4-5") == "Haiku 4.5")
        #expect(ModelName.display("claude-fable-5") == "Fable 5")
    }

    @Test func bracketedVariantsKeepTheirQualifier() {
        // the 1M-context variant, seen live; the bracket must not be parsed
        // as part of the version ("Opus 5[1m] 5")
        #expect(ModelName.display("claude-opus-5-5[1m]") == "Opus 5.5 1M")
        #expect(ModelName.display("claude-sonnet-5[1m]") == "Sonnet 5 1M")
        // a malformed bracket must not swallow the name
        #expect(ModelName.display("claude-opus-5-5[]") == "Opus 5.5")
        // an id that is nothing but a qualifier has no name to strip to —
        // whatever comes back, it must not be empty
        #expect(!ModelName.display("[1m]").isEmpty)
    }

    @Test func datedIdsDropTheDate() {
        #expect(ModelName.display("claude-haiku-4-5-20251001") == "Haiku 4.5")
    }

    @Test func codexFamilies() {
        #expect(ModelName.display("gpt-6-astra") == "Astra 6")
        #expect(ModelName.display("gpt-6.1-sol") == "Sol 6.1")
        #expect(ModelName.display("gpt-5.6-sol") == "Sol 5.6")
        #expect(ModelName.display("gpt-5.1-codex-mini") == "Codex mini 5.1")
    }

    @Test func versionOnlyIdsKeepTheirVendor() {
        #expect(ModelName.display("gpt-5.4") == "GPT-5.4")
        #expect(ModelName.display("gpt-5.6") == "GPT-5.6")
    }

    @Test func unknownIdsDegradeGracefully() {
        // new models ship constantly; never blank, never crash
        #expect(ModelName.display("some-future-model-9") == "Some future model 9")
        #expect(ModelName.display("o3") == "O3")
        #expect(ModelName.display("") == "")
        #expect(ModelName.display("   ") == "   ")
    }
}
