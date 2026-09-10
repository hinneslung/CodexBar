#if os(Windows)
import Foundation
import Testing
@testable import CodexBarWindows

@Suite("Windows named provider profiles")
struct WindowsNamedProviderProfileTests {
    @Test
    func `legacy configuration migrates stable default identities and round trips`() throws {
        let legacy = Data(
            """
            {"schemaVersion":7,"providers":[
              {"id":"codex","enabled":true,"order":0,"sourceMode":"automatic"},
              {"id":"poe","enabled":true,"order":1,"sourceMode":"wsl","wslDistro":"Ubuntu"}
            ]}
            """.utf8)
        let decoded = try JSONDecoder().decode(WindowsAppConfiguration.self, from: legacy)
            .mergingCatalogDefaults()
        let codex = try #require(decoded.providers.first { $0.id == .codex })
        let poe = try #require(decoded.providers.first { $0.id == .poe })
        #expect(codex.profileID == .defaultID(for: .codex))
        #expect(poe.profileID == .defaultID(for: .poe))
        #expect(codex.profileName == "Default")
        let roundTrip = try JSONDecoder().decode(
            WindowsAppConfiguration.self,
            from: JSONEncoder().encode(decoded))
        #expect(roundTrip == decoded)
        #expect(roundTrip.mergingCatalogDefaults().providers.count == decoded.providers.count)
    }

    @Test
    func `new profiles use unique IDs and start without copied routing or credentials`() throws {
        var configuration = WindowsAppConfiguration.defaults
        let original = try #require(configuration.providers.first { $0.id == .codex })
        let addedValue = configuration.addProfile(for: .codex)
        let added = try #require(addedValue)
        #expect(added.profileID != original.profileID)
        #expect(Foundation.UUID(uuidString: added.profileID.rawValue) != nil)
        #expect(added.sourceMode == .automatic)
        #expect(added.wslDistro == nil)
        #expect(added.companionValues.isEmpty)
        #expect(added.codexHome == nil)
        #expect(configuration.profileCount(for: .codex) == 2)
        let removedOriginal = configuration.removeProfile(original.profileID)
        let removedSoleProfile = configuration.removeProfile(added.profileID)
        #expect(removedOriginal)
        #expect(!removedSoleProfile)
    }

    @Test
    func `duplicate and cross provider reserved identities fail decoding`() {
        let duplicate = Data(
            """
            {"providers":[
              {"id":"codex","profileID":"codex"},
              {"id":"codex","profileID":"codex"}
            ]}
            """.utf8)
        let crossProvider = Data(
            """
            {"providers":[{"id":"poe","profileID":"codex"}]}
            """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WindowsAppConfiguration.self, from: duplicate)
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WindowsAppConfiguration.self, from: crossProvider)
        }
    }

    @Test
    func `profile names and Codex homes enforce safe bounded input`() {
        #expect(WindowsProviderProfileValidation.normalizedName("  Work  ") == "Work")
        #expect(WindowsProviderProfileValidation.normalizedName("") == "")
        #expect(WindowsProviderProfileValidation.normalizedName("   ") == "")
        #expect(WindowsProviderProfileValidation.normalizedName("bad\u{202E}name") == nil)
        #expect(WindowsProviderProfileValidation.normalizedCodexHome(" ~/.codex-personal ") == "~/.codex-personal")
        #expect(WindowsProviderProfileValidation
            .normalizedCodexHome("/home/user/Codex Work") == "/home/user/Codex Work")
        for invalid in ["C:\\Users\\person", "relative", "/home/person/../other", "/home/person;touch"] {
            #expect(WindowsProviderProfileValidation.normalizedCodexHome(invalid) == nil)
        }
    }

    @Test
    func `blank profile names persist while missing legacy names remain default`() throws {
        let explicitBlank = WindowsProviderConfiguration(
            id: .codex,
            profileID: .init(rawValue: "blank-profile"),
            profileName: "   ",
            enabled: true,
            order: 0)
        #expect(explicitBlank.profileName == "")
        let roundTrip = try JSONDecoder().decode(
            WindowsProviderConfiguration.self,
            from: JSONEncoder().encode(explicitBlank))
        #expect(roundTrip.profileName == "")

        let legacy = Data(#"{"id":"codex","enabled":true,"order":0}"#.utf8)
        let legacyProfile = try JSONDecoder().decode(WindowsProviderConfiguration.self, from: legacy)
        #expect(legacyProfile.profileName == WindowsProviderProfileValidation.defaultName)
    }

    @Test
    func `one blank name is valid while a second blank is a duplicate for its provider`() {
        let blank = WindowsProviderConfiguration(
            id: .codex,
            profileID: .init(rawValue: "blank-one"),
            profileName: "",
            enabled: true,
            order: 0)
        let secondBlank = WindowsProviderConfiguration(
            id: .codex,
            profileID: .init(rawValue: "blank-two"),
            profileName: "   ",
            enabled: true,
            order: 1)
        let otherProviderBlank = WindowsProviderConfiguration(
            id: .poe,
            profileID: .init(rawValue: "blank-poe"),
            profileName: "",
            enabled: true,
            order: 2)
        #expect(!WindowsProviderProfileValidation.hasDuplicateName(blank, among: [blank]))
        #expect(WindowsProviderProfileValidation.hasDuplicateName(secondBlank, among: [blank]))
        #expect(!WindowsProviderProfileValidation.hasDuplicateName(otherProviderBlank, among: [blank]))
    }

    @Test
    func `Codex staged config selects only the requested profile home with automatic source`() throws {
        let path = "/home/person/.codex-personal"
        let data = try WindowsStagedProviderConfig.encodeCodexHome(path)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        let codex = try #require(providers.first)
        #expect(codex["source"] as? String == "auto")
        #expect(codex["codexProfileHomePaths"] as? [String] == [path])
        let active = try #require(codex["codexActiveSource"] as? [String: Any])
        #expect(active["kind"] as? String == "liveSystem")
        #expect(active["homePath"] as? String == path)
        #expect(String(decoding: data, as: UTF8.self).contains("managedAccount") == false)
    }

    @Test
    func `Codex home resolves tilde absolute spaces and missing directory without fallback`() throws {
        #expect(try WindowsConfiguredProviderDataSource.resolveCodexHome(
            "~/.codex-personal",
            distribution: "Ubuntu",
            defaultLinuxHome: { "/home/person" },
            directoryExists: { $0 == "/home/person/.codex-personal" }) == "/home/person/.codex-personal")
        #expect(try WindowsConfiguredProviderDataSource.resolveCodexHome(
            "/home/person/Codex Work",
            distribution: "Ubuntu",
            directoryExists: { $0 == "/home/person/Codex Work" }) == "/home/person/Codex Work")
        #expect(throws: WindowsStagedProviderConfigError.self) {
            _ = try WindowsConfiguredProviderDataSource.resolveCodexHome(
                "/home/person/missing",
                distribution: "Ubuntu",
                directoryExists: { _ in false })
        }

        let invalidProfile = WindowsProviderConfiguration(
            id: .codex,
            enabled: true,
            order: 0,
            codexHome: "relative-home")
        #expect(invalidProfile.codexHome == "relative-home")
        #expect(throws: WindowsStagedProviderConfigError.self) {
            _ = try WindowsConfiguredProviderDataSource.resolveCodexHome(
                #require(invalidProfile.codexHome),
                distribution: "Ubuntu",
                directoryExists: { _ in true })
        }
    }

    @Test
    func `legacy encrypted record without profile identity loads from original provider file`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarLegacyProfileVault-\(Foundation.UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WindowsProviderCredentialVault(directoryURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let revision = Foundation.UUID().uuidString.lowercased()
        let plaintext = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": WindowsProviderCredentialRecord.currentSchemaVersion,
            "providerID": "poe",
            "credentialSetID": "api-key",
            "revision": revision,
            "values": ["apiKey": "synthetic-legacy-key"],
        ])
        try WindowsProviderCredentialVault.protect(plaintext)
            .write(to: root.appendingPathComponent("poe.bin"))

        let loaded = try vault.load(.poe)
        let record = try #require(loaded)
        #expect(record.profileID == WindowsProviderProfileID.defaultID(for: .poe).rawValue)
        #expect(record.revision == revision)
        #expect(record.values["apiKey"] == "synthetic-legacy-key")
        #expect(vault.contains(provider: .poe, profileID: .defaultID(for: .poe)))
    }

    @Test
    func `same provider browser sessions save load and clear independently by profile`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarBrowserProfiles-\(Foundation.UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WindowsProviderCredentialVault(directoryURL: root)
        let work = WindowsProviderProfileID(rawValue: "browser-work")
        let personal = WindowsProviderProfileID(rawValue: "browser-personal")
        try vault.save(
            provider: .openCodeGo,
            profileID: work,
            credentialSetID: "browser-session",
            submittedValues: ["cookieHeader": "auth=synthetic-work-session"])
        try vault.save(
            provider: .openCodeGo,
            profileID: personal,
            credentialSetID: "browser-session",
            submittedValues: ["cookieHeader": "auth=synthetic-personal-session"])

        #expect(try vault.load(.openCodeGo, profileID: work)?.values["cookieHeader"]
            == "auth=synthetic-work-session")
        #expect(try vault.load(.openCodeGo, profileID: personal)?.values["cookieHeader"]
            == "auth=synthetic-personal-session")
        try vault.clear(.openCodeGo, profileID: work)
        #expect(try vault.load(.openCodeGo, profileID: work) == nil)
        #expect(try vault.load(.openCodeGo, profileID: personal)?.values["cookieHeader"]
            == "auth=synthetic-personal-session")
    }

    @Test
    func `same provider credentials save and clear independently by profile`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarNamedProfiles-\(Foundation.UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WindowsProviderCredentialVault(directoryURL: root)
        let work = WindowsProviderProfileID(rawValue: "work-profile")
        let personal = WindowsProviderProfileID(rawValue: "personal-profile")
        try vault.save(
            provider: .poe,
            profileID: work,
            credentialSetID: "api-key",
            submittedValues: ["apiKey": "work-secret"])
        try vault.save(
            provider: .poe,
            profileID: personal,
            credentialSetID: "api-key",
            submittedValues: ["apiKey": "personal-secret"])
        #expect(try vault.load(.poe, profileID: work)?.values["apiKey"] == "work-secret")
        #expect(try vault.load(.poe, profileID: personal)?.values["apiKey"] == "personal-secret")
        let impostor = WindowsProviderProfileID(rawValue: "impostor-profile")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("work-profile.bin"),
            to: root.appendingPathComponent("impostor-profile.bin"))
        #expect(throws: WindowsProviderCredentialVaultError.corruptedCredential) {
            _ = try vault.load(.poe, profileID: impostor)
        }
        try vault.clear(.poe, profileID: work)
        #expect(try vault.load(.poe, profileID: work) == nil)
        #expect(try vault.load(.poe, profileID: personal)?.values["apiKey"] == "personal-secret")
    }

    @Test
    func `profile removal skips nonexistent Codex vault schema and clears manual profile only`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarRemoval-\(Foundation.UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WindowsProviderCredentialVault(directoryURL: root)
        let client = WindowsProviderConfigurationClient(vault: vault)
        let service = WindowsProviderProfileRemovalService(configurationClient: client)
        let codex = WindowsProviderConfiguration(
            id: .codex,
            profileID: .init(rawValue: "codex-temporary"),
            enabled: true,
            order: 0)
        try service.removeAppOwnedCredential(for: codex)

        let poe = WindowsProviderConfiguration(
            id: .poe,
            profileID: .init(rawValue: "poe-temporary"),
            enabled: true,
            order: 0)
        try vault.save(
            provider: .poe,
            profileID: poe.profileID,
            credentialSetID: "api-key",
            submittedValues: ["apiKey": "temporary-secret"])
        #expect(vault.contains(provider: .poe, profileID: poe.profileID))
        try service.removeAppOwnedCredential(for: poe)
        #expect(!vault.contains(provider: .poe, profileID: poe.profileID))
    }

    @Test
    func `configured datasource keeps concurrent same provider profiles and authority separate`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarDataSourceProfiles-\(Foundation.UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WindowsConfigurationStore(fileURL: root.appendingPathComponent("config.json"))
        let vault = WindowsProviderCredentialVault(directoryURL: root.appendingPathComponent("Credentials"))
        let workID = WindowsProviderProfileID(rawValue: "datasource-work")
        let personalID = WindowsProviderProfileID(rawValue: "datasource-personal")
        try store.save(WindowsAppConfiguration(providers: [
            WindowsProviderConfiguration(
                id: .poe,
                profileID: workID,
                profileName: "Work",
                enabled: true,
                order: 0),
            WindowsProviderConfiguration(
                id: .poe,
                profileID: personalID,
                profileName: "Personal",
                enabled: true,
                order: 1),
        ]))
        try vault.save(
            provider: .poe,
            profileID: workID,
            credentialSetID: "api-key",
            submittedValues: ["apiKey": "synthetic-work-key"])
        try vault.save(
            provider: .poe,
            profileID: personalID,
            credentialSetID: "api-key",
            submittedValues: ["apiKey": "synthetic-personal-key"])
        let runner = NamedProfileRunner()
        let client = WindowsCanonicalCLIProviderClient(
            processRunner: { _, _, _, _, _, standardInput in
                try runner.run(standardInput: standardInput)
            },
            retryDelay: {})
        let dataSource = WindowsConfiguredProviderDataSource(
            store: store,
            environment: ["WINDIR": "C:\\Windows"],
            wslDistributions: ["Ubuntu"],
            cliDiscoveryCache: WindowsCanonicalCLIDiscoveryCache(
                resolver: { _, _ in "/usr/local/bin/codexbar" }),
            bundledCLIDiscoveryCache: WindowsCanonicalCLIDiscoveryCache(
                resolver: { _, _ in "/opt/codexbar/CodexBarCLI" }),
            cliClient: client,
            credentialVault: vault)

        let fetch = Task { await dataSource.fetchProviderSnapshots() }
        #expect(runner.waitForBothProfiles())
        runner.releaseBothProfiles()
        let snapshots = await fetch.value
        #expect(snapshots.map(\.profileID) == [workID, personalID])
        #expect(snapshots.map(\.profileName) == ["Work", "Personal"])
        #expect(snapshots.map(\.usedPercent) == [21, 67])
        #expect(snapshots.map(\.accountText) == ["work-account", "personal-account"])
        #expect(runner.callCount == 2)

        try vault.save(
            provider: .poe,
            profileID: workID,
            credentialSetID: "api-key",
            submittedValues: ["apiKey": "synthetic-work-key-replaced"])
        var committed: [WindowsProviderProfileID] = []
        let outcome = WindowsProviderSnapshotPublisher.publish(snapshots) {
            committed.append($0.profileID)
        }
        #expect(outcome.rejectedProfiles == [workID])
        #expect(committed == [personalID])
    }

    @Test
    func `presentation distinguishes named profiles while leaving one default familiar`() {
        let personalID = WindowsProviderProfileID(rawValue: "personal-profile")
        let work = WindowsProviderConfiguration(
            id: .codex,
            profileName: "Work",
            enabled: true,
            order: 0)
        let personal = WindowsProviderConfiguration(
            id: .codex,
            profileID: personalID,
            profileName: "Personal",
            enabled: true,
            order: 1)
        let snapshots = [
            WindowsProviderSnapshot(provider: .codex, availability: .available, sourceText: "Automatic"),
            WindowsProviderSnapshot(
                provider: .codex,
                profileID: personalID,
                profileName: "Personal",
                availability: .available,
                sourceText: "Automatic"),
        ]
        let rows = WindowsDashboardPresentation.make(
            snapshots: snapshots,
            refreshedAt: Date(),
            profiles: [work, personal]).rows
        #expect(rows.map(\.displayName) == ["Codex - Work", "Codex - Personal"])
        #expect(rows[0].accessibilityText.hasPrefix("Codex - Work. "))
        #expect(rows[0].dashboardText.hasPrefix("Codex - Work —"))
        #expect(
            WindowsDashboardPresentation(
                rows: rows,
                refreshedAt: Date(),
                isRefreshing: false).trayTooltip(showUsed: true).hasPrefix("Codex - Work - "))
        let onlyWork = WindowsDashboardPresentation.make(
            snapshots: [snapshots[0]],
            refreshedAt: Date(),
            profiles: [work]).rows
        #expect(onlyWork.first?.displayName == "Codex - Work")
        let defaultOnly = WindowsDashboardPresentation.make(
            snapshots: [snapshots[0]],
            refreshedAt: Date(),
            profiles: [WindowsProviderConfiguration(id: .codex, enabled: true, order: 0)]).rows
        #expect(defaultOnly.first?.displayName == "Codex")

        let blank = WindowsProviderConfiguration(
            id: .codex,
            profileID: .init(rawValue: "blank-profile"),
            profileName: "",
            enabled: true,
            order: 0)
        let blankRow = WindowsDashboardPresentation.make(
            snapshots: [],
            refreshedAt: Date(),
            profiles: [blank]).rows.first
        #expect(blankRow?.displayName == "Codex")
        #expect(blankRow?.accessibilityText.hasPrefix("Codex. ") == true)
        #expect(blankRow?.dashboardText.hasPrefix("Codex —") == true)
    }

    @Test
    func `automatic staged invocation keeps exact CLI source and presentation attribution`() {
        let config = Data("{\"version\":1}".utf8)
        let invocation = WindowsCanonicalCLIInvocation.stagedWSL(
            distribution: "Ubuntu",
            launcherPath: "/opt/codexbar/CodexBarStagingLauncher",
            providerID: "codex",
            source: "auto",
            config: config,
            credentialPath: "Automatic",
            windowsDirectory: "C:\\Windows",
            presentsAsAutomatic: true)
        #expect(invocation.arguments == [
            "-d", "Ubuntu", "--", "/opt/codexbar/CodexBarStagingLauncher",
            "--timeout-seconds", "50", "--provider", "codex", "--source", "auto",
            "--mode", "usage",
        ])
        #expect(invocation.standardInput == config)
        #expect(invocation.source.kind == .automatic)
        #expect(invocation.source.formattedValue == "Ubuntu · Automatic")
    }

    @Test
    func `publication authority rejects one profile without crossing same provider sibling`() {
        let workID = WindowsProviderProfileID(rawValue: "work-profile")
        let personalID = WindowsProviderProfileID(rawValue: "personal-profile")
        let snapshots = [
            WindowsProviderSnapshot(
                provider: .codex,
                profileID: workID,
                availability: .available,
                sourceText: "Automatic",
                publicationAuthorityCheck: { false }),
            WindowsProviderSnapshot(
                provider: .codex,
                profileID: personalID,
                availability: .available,
                sourceText: "Automatic",
                publicationAuthorityCheck: { true }),
        ]
        var committed: [WindowsProviderProfileID] = []
        let outcome = WindowsProviderSnapshotPublisher.publish(snapshots) {
            committed.append($0.profileID)
        }
        #expect(committed == [personalID])
        #expect(outcome.rejectedProfiles == [workID])
        #expect(outcome.rejectedProviders == [.codex])
    }

    @Test
    func `routing changes invalidate caches while rename alone does not`() {
        let work = WindowsProviderConfiguration(
            id: .codex,
            profileName: "Work",
            enabled: true,
            order: 0,
            sourceMode: .wsl,
            wslDistro: "Ubuntu",
            codexHome: "/home/person/.codex")
        var renamed = work
        renamed.profileName = "Personal"
        #expect(WindowsProviderConfigurationPageState.hasUnsavedChanges(draft: renamed, saved: work))
        #expect(!WindowsTrayApplication.routingChanged(from: work, to: renamed))
        renamed.codexHome = "/home/person/.codex-personal"
        #expect(WindowsTrayApplication.routingChanged(from: work, to: renamed))
    }
}

private final class NamedProfileRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var calls = 0

    var callCount: Int {
        self.lock.withLock { self.calls }
    }

    func waitForBothProfiles() -> Bool {
        self.entered.wait(timeout: .now() + 2) == .success
            && self.entered.wait(timeout: .now() + 2) == .success
    }

    func releaseBothProfiles() {
        self.release.signal()
        self.release.signal()
    }

    func run(standardInput: Data?) throws -> WindowsHiddenProcessResult {
        let input = try #require(standardInput)
        let text = String(decoding: input, as: UTF8.self)
        let account: String
        let usedPercent: Int
        if text.contains("synthetic-work-key") {
            account = "work-account"
            usedPercent = 21
        } else if text.contains("synthetic-personal-key") {
            account = "personal-account"
            usedPercent = 67
        } else {
            throw WindowsCanonicalCLIError.invalidPayload
        }
        self.lock.withLock { self.calls += 1 }
        self.entered.signal()
        guard self.release.wait(timeout: .now() + 5) == .success else {
            throw WindowsCanonicalCLIError.timedOut
        }
        let payload = Data(
            """
            [{"provider":"poe","account":"\(account)","source":"api",\
            "usage":{"primary":{"usedPercent":\(usedPercent)}},"credits":null,"error":null}]
            """.utf8)
        return WindowsHiddenProcessResult(
            standardOutput: payload,
            standardError: Data(),
            exitCode: 0)
    }
}
#endif
