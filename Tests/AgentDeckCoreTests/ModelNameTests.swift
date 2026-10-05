import Testing
@testable import AgentDeckCore

struct ModelNameTests {
    @Test func claudeFamilies() {
        // ids observed live on this machine
        #expect(ModelName.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelName.display("claude-sonnet-5") == "Sonnet 5")
        #expect(ModelName.display("claude-haiku-4-5") == "Haiku 4.5")
        #expect(ModelName.display("claude-fable-5-1") == "Fable 5.1")
    }

    @Test func codexFamilies() {
        #expect(ModelName.display("gpt-6-astra") == "Astra 6")
        #expect(ModelName.display("gpt-6.1-sol") == "Sol 6.1")
        #expect(ModelName.display("gpt-5.6-sol") == "Sol 5.6")
        #expect(ModelName.display("gpt-5.1-codex-mini") == "Codex mini 5.1")
    }

    @Test func bracketedVariantsKeepTheirQualifier() {
        // the 1M-context variant, seen live; the bracket must not be parsed
        // as part of the version ("Opus 5[1m] 5")
        #expect(ModelName.display("claude-opus-5-5[1m]") == "Opus 5.5 1M")
        #expect(ModelName.display("claude-sonnet-5[1m]") == "Sonnet 5 1M")
        #expect(ModelName.display("claude-opus-5-5[]") == "Opus 5.5")
    }

    @Test func bracketsInAnyOtherShapeArePassedThroughUntouched() {
        // Guessing at a shape we don't understand is what produced
        // "Opus 5[1m 5". An unparsed id is the better failure.
        #expect(ModelName.display("claude-opus-5-5[1m") == "claude-opus-5-5[1m")
        #expect(ModelName.display("claude-opus-5[1m]5") == "claude-opus-5[1m]5")
        #expect(ModelName.display("claude-opus-5-5[1m][fast]")
                == "claude-opus-5-5[1m][fast]")
        #expect(ModelName.display("[1m]") == "[1m]")
    }

    @Test func dateStampsAreNotVersions() {
        // Anthropic's compact form and OpenAI's hyphenated snapshot pins.
        // The hyphenated one used to yield "GPT-5.08.07" — the month and
        // day were short enough to read as version components.
        #expect(ModelName.display("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelName.display("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ModelName.display("gpt-5-2025-08-07") == "GPT-5")
        #expect(ModelName.display("o3-2025-04-16") == "O3")
        #expect(ModelName.display("gpt-4o-2024-08-06") == "GPT-4o")
    }

    @Test func idsWithNoFamilyNameKeepTheirVendor() {
        // "4O" on its own identifies nothing
        #expect(ModelName.display("gpt-5.4") == "GPT-5.4")
        #expect(ModelName.display("gpt-4o") == "GPT-4o")
        #expect(ModelName.display("o3") == "O3")
    }

    @Test func everyVersionComponentSurvives() {
        // a first-one-wins rule silently dropped the rest
        #expect(ModelName.display("foo-1-2.3") == "Foo 1.2.3")
        #expect(ModelName.display("foo-1.2.3") == "Foo 1.2.3")
    }

    @Test func unknownIdsDegradeGracefully() {
        // new models ship constantly; never blank, never crash
        #expect(ModelName.display("some-future-model-9") == "Some future model 9")
        #expect(ModelName.display("") == "")
        #expect(ModelName.display("   ") == "   ")
        // a stray newline used to end up inside the label ("Sonnet 5\n 4")
        #expect(ModelName.display("claude-sonnet-4-5\n") == "Sonnet 4.5")
    }

    @Test func sameModelIgnoringTheVariantQualifier() {
        #expect(ModelName.sameBaseModel("claude-opus-5-5[1m]", "claude-opus-5-5"))
        #expect(ModelName.sameBaseModel("claude-opus-5-5", "claude-opus-5-5"))
        #expect(!ModelName.sameBaseModel("claude-opus-5-5[1m]", "claude-fable-5-1"))
        // 5 and 5.5 are different models, not a qualifier apart
        #expect(!ModelName.sameBaseModel("claude-opus-5-5", "claude-opus-5"))
    }

    @Test func absurdlyLongNamesCannotEatTheRow() {
        let long = "claude-" + String(repeating: "verylongname-", count: 10) + "9"
        let shown = ModelName.display(long)
        #expect(shown.count <= ModelName.maxLength)
        #expect(shown.hasSuffix("…"))
    }
}
