#if canImport(CodexBarWindows)
import Foundation
import Testing
@testable import CodexBarWindows

@Suite("Windows provider credential bridge")
struct WindowsProviderCredentialBridgeTests {
    @Test
    func `API credentials are scoped to the requested provider`() throws {
        let bridge = Self.bridge(
            """
            {"poe":{"type":"api","key":"fixture-token"}}
            """)

        let overrides = try bridge.environmentOverrides(
            for: .poe,
            base: ["WSLENV": "EXISTING/u"])
        #expect(overrides["POE_API_KEY"] == "fixture-token")
        #expect(overrides["WSLENV"] == "EXISTING/u:POE_API_KEY")
        #expect(overrides["COPILOT_API_TOKEN"] == nil)
    }

    @Test
    func `OAuth access is accepted only by an explicitly allowed mapping`() throws {
        let bridge = Self.bridge(
            """
            {
              "github-copilot":{"type":"oauth","access":"copilot-oauth"},
              "openrouter":{"type":"oauth","access":"unapproved-oauth"}
            }
            """)

        let copilot = try bridge.environmentOverrides(
            for: .copilot,
            base: [:])
        let openRouter = try bridge.environmentOverrides(
            for: .openRouter,
            base: [:])
        #expect(copilot["COPILOT_API_TOKEN"] == "copilot-oauth")
        #expect(openRouter.isEmpty)
    }

    @Test
    func `Poe accepts either API or approved OAuth credentials`() throws {
        let api = try Self.bridge(
            """
            {"poe":{"type":"api","key":"poe-api"}}
            """).environmentOverrides(for: .poe, base: [:])
        let oauth = try Self.bridge(
            """
            {"poe":{"type":"oauth","access":"poe-oauth"}}
            """).environmentOverrides(for: .poe, base: [:])
        #expect(api["POE_API_KEY"] == "poe-api")
        #expect(oauth["POE_API_KEY"] == "poe-oauth")
    }

    @Test
    func `aliases select their matching environment and region`() throws {
        let bridge = Self.bridge(
            """
            {
              "moonshotai-cn":{"type":"api","key":"moonshot-secret"},
              "zhipuai-coding-plan":{"type":"api","key":"zhipu-secret"}
            }
            """)

        let moonshot = try bridge.environmentOverrides(
            for: .moonshot,
            base: [:])
        let zai = try bridge.environmentOverrides(
            for: .zai,
            base: [:])
        #expect(moonshot["MOONSHOT_API_KEY"] == "moonshot-secret")
        #expect(moonshot["MOONSHOT_REGION"] == "china")
        #expect(zai["ZHIPU_API_KEY"] == "zhipu-secret")
        #expect(zai["Z_AI_REGION"] == "bigmodel-cn")
        #expect(zai["WSLENV"] == "ZHIPU_API_KEY:Z_AI_REGION")
    }

    @Test
    func `CN aliases without an upstream region environment fail closed`() throws {
        let bridge = Self.bridge(
            """
            {
              "alibaba-coding-plan-cn":{"type":"api","key":"alibaba-cn-secret"},
              "minimax-cn-coding-plan":{"type":"api","key":"minimax-cn-secret"}
            }
            """)

        #expect(
            try bridge.environmentOverrides(
                for: .alibaba,
                base: [:]).isEmpty)
        #expect(
            try bridge.environmentOverrides(
                for: .minimax,
                base: [:]).isEmpty)
    }

    @Test
    func `all declarative mappings use unique CodexBar provider IDs`() {
        let rules = WindowsProviderCredentialBridge.defaultRules
        #expect(rules.count == 20)
        #expect(Set(rules.map(\.provider)).count == rules.count)
    }

    @Test
    func `every approved API mapping projects its canonical environment key`() throws {
        let mappings: [(WindowsProviderID, String, String)] = [
            (.aiAnd, "aiand", "AIAND_API_KEY"),
            (.alibaba, "alibaba-coding-plan", "ALIBABA_CODING_PLAN_API_KEY"),
            (.chutes, "chutes", "CHUTES_API_KEY"),
            (.clinePass, "cline-pass", "CLINE_API_KEY"),
            (.crof, "crof", "CROF_API_KEY"),
            (.deepInfra, "deepinfra", "DEEPINFRA_API_KEY"),
            (.deepSeek, "deepseek", "DEEPSEEK_API_KEY"),
            (.fireworks, "fireworks-ai", "FIREWORKS_API_KEY"),
            (.kilo, "kilo", "KILO_API_KEY"),
            (.kimi, "kimi-for-coding", "KIMI_CODE_API_KEY"),
            (.minimax, "minimax-coding-plan", "MINIMAX_API_KEY"),
            (.moonshot, "moonshotai", "MOONSHOT_API_KEY"),
            (.ollama, "ollama-cloud", "OLLAMA_API_KEY"),
            (.openCodeGo, "opencode-go", "OPENCODE_API_KEY"),
            (.openRouter, "openrouter", "OPENROUTER_API_KEY"),
            (.poe, "poe", "POE_API_KEY"),
            (.synthetic, "synthetic", "SYNTHETIC_API_KEY"),
            (.venice, "venice", "VENICE_API_KEY"),
            (.zai, "zai", "Z_AI_API_KEY"),
        ]
        for (provider, authProvider, environmentKey) in mappings {
            let secret = "fixture-\(authProvider)"
            let data = try JSONSerialization.data(withJSONObject: [
                authProvider: ["type": "api", "key": secret],
            ])
            let bridge = WindowsProviderCredentialBridge(authDataLoader: { _ in data })
            let overrides = try bridge.environmentOverrides(
                for: provider,
                base: [:])
            #expect(overrides[environmentKey] == secret, "Missing mapping for \(provider)")
        }
    }

    @Test
    func `default loader reads only the selected WSL OpenCode data home`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(
            """
            {"opencode-go":{"type":"api","key":"selected-wsl-token"}}
            """.utf8).write(to: directory.appendingPathComponent("auth.json"))

        let overrides = try WindowsProviderCredentialBridge().environmentOverrides(
            for: .openCodeGo,
            base: [WindowsProviderCredentialBridge.wslOpenCodeDataHomeEnvironmentKey: directory.path])
        #expect(overrides["OPENCODE_API_KEY"] == "selected-wsl-token")
    }

    @Test
    func `errors never include credential contents`() {
        let secret = "must-never-appear"
        let bridge = Self.bridge(
            """
            {"github-copilot":{"type":"oauth","access":"\(secret)","expires":1}}
            """)
        do {
            _ = try bridge.environmentOverrides(
                for: .copilot,
                base: [:])
            Issue.record("Expected expired credential error")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
            #expect(error.localizedDescription.contains("github-copilot"))
        }
    }

    @Test
    func `zero OAuth expiry is treated as an unspecified lifetime`() throws {
        let overrides = try Self.bridge(
            """
            {"github-copilot":{"type":"oauth","access":"copilot-oauth","expires":0}}
            """).environmentOverrides(for: .copilot, base: [:])
        #expect(overrides["COPILOT_API_TOKEN"] == "copilot-oauth")
    }

    @Test
    func `providers without a mapping leave the child environment untouched`() throws {
        let overrides = try Self.bridge(
            """
            {"gemini":{"type":"api","key":"fixture-token"}}
            """).environmentOverrides(for: .gemini, base: [:])
        #expect(overrides.isEmpty)
    }

    @Test
    func `WSL environment entries are merged by variable name`() {
        let merged = WindowsProviderCredentialBridge.mergedWSLEnvironment(
            existing: "PATH/l:Token/u",
            adding: ["TOKEN", "NEW_VALUE"])
        #expect(merged == "PATH/l:Token/u:NEW_VALUE")
    }

    private static func bridge(_ json: String) -> WindowsProviderCredentialBridge {
        let data = Data(json.utf8)
        return WindowsProviderCredentialBridge(authDataLoader: { _ in data })
    }
}
#endif
