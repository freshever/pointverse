import XCTest
@testable import PointVerseKit

final class ExternalLanguageModelTests: XCTestCase {
    func testNetworkModelRoundTripsAndCanBeSelected() throws {
        let suite = "ExternalLanguageModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ExternalLanguageModel(
            name: "OpenRouter Free",
            kind: .openAICompatible,
            provider: .openRouter,
            baseURL: ExternalLanguageModelProvider.openRouter.defaultBaseURL,
            remoteModel: "openrouter/free"
        )

        ExternalLanguageModelStore.save([model], defaults: defaults)
        defaults.set(model.selectionID, forKey: ModelSelection.languageDefaultsKey)

        XCTAssertEqual(ExternalLanguageModelStore.selected(defaults: defaults), model)
    }

    func testPrivacyApprovalIsPerModelAndRevocable() throws {
        let suite = "ExternalLanguageModelApprovalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID()
        let second = UUID()

        ExternalModelPrivacyApprovalStore.approve(first, defaults: defaults)
        XCTAssertTrue(ExternalModelPrivacyApprovalStore.isApproved(first, defaults: defaults))
        XCTAssertFalse(ExternalModelPrivacyApprovalStore.isApproved(second, defaults: defaults))

        ExternalModelPrivacyApprovalStore.revoke(first, defaults: defaults)
        XCTAssertFalse(ExternalModelPrivacyApprovalStore.isApproved(first, defaults: defaults))
    }

    func testCapabilitiesRoundTripAndLegacyModelsRemainLanguageOnly() throws {
        let configured = ExternalLanguageModel(
            name: "Multi-purpose",
            kind: .openAICompatible,
            provider: .custom,
            baseURL: "https://example.com/v1",
            remoteModel: "model",
            capabilities: [.language, .embedding, .imageGeneration]
        )
        let decoded = try JSONDecoder().decode(
            ExternalLanguageModel.self,
            from: JSONEncoder().encode(configured)
        )
        XCTAssertTrue(decoded.supports(.embedding))
        XCTAssertTrue(decoded.supports(.imageGeneration))
        XCTAssertFalse(decoded.supports(.speech))

        let legacyJSON = """
        {"id":"\(UUID().uuidString)","name":"Legacy","kind":"openAICompatible","provider":"openRouter","baseURL":"https://openrouter.ai/api/v1","remoteModel":"openrouter/free"}
        """
        let legacy = try JSONDecoder().decode(ExternalLanguageModel.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.supportedCapabilities, [.language])
    }
}
