import XCTest
@testable import MarsPad
final class ModelTests: XCTestCase {
    func testSoundClassificationAvoidsSubstringMatches() {
        XCTAssertEqual(classify("808/WAV/01_Kick/kick_001.wav"), "Kick")
        XCTAssertEqual(classify("606/Open Hats/OH_02.wav"), "Open Hat")
        XCTAssertEqual(classify("808 Loops From Mars/BD_loop.wav"), "Loops")
        XCTAssertEqual(classify("Synth/Orbit.wav"), "Other")
        XCTAssertEqual(classify("Drums/SD_01.wav"), "Snare")
    }
    func testKitRoundTripKeepsAllBanksAndUnicodePaths() throws {
        var kit = Kit()
        kit.pads[127] = Sample(path: "/library/café/hat.wav", collection: "café", category: "Closed Hat")
        let restored = try JSONDecoder().decode(Kit.self, from: JSONEncoder().encode(kit))
        XCTAssertEqual(restored.pads.count, 128)
        XCTAssertEqual(restored.pads[127]?.path, kit.pads[127]?.path)
        XCTAssertNil(restored.pads[0])
    }
    @MainActor func testAutoFillPreservesExistingPadsAndUsesFilters() {
        let model = Library()
        let first = Sample(path: "/one/kick.wav", collection: "One", category: "Kick")
        let second = Sample(path: "/two/snare.wav", collection: "Two", category: "Snare")
        model.samples = [first, second]; model.kit.pads[0] = first
        model.collection = "Two"; model.autoFill()
        XCTAssertEqual(model.kit.pads[0], first)
        XCTAssertEqual(model.kit.pads[2], second)
        XCTAssertEqual(model.kit.pads.compactMap { $0 }.count, 2)
    }
    @MainActor func testAutoFillCompletesSingleCategoryBankAndExplainsShortage() {
        let model = Library()
        model.samples = (0..<20).map { Sample(path: "/kick-\($0).wav", collection: "Test", category: "Kick") }
        model.category = "Kick"
        model.autoFill()
        XCTAssertEqual(model.kit.pads.prefix(16).compactMap { $0 }.count, 16)
        let firstBank = Array(model.kit.pads.prefix(16))
        model.bank = 7
        model.autoFill()
        XCTAssertEqual(Array(model.kit.pads.prefix(16)), firstBank)
        XCTAssertEqual(model.kit.pads.suffix(16).compactMap { $0 }.count, 4)
        XCTAssertEqual(Set(model.kit.pads.compactMap { $0?.path }).count, 20)
        XCTAssertTrue(model.status.contains("12 still empty"))
        let before = model.kit.pads
        model.autoFill()
        XCTAssertEqual(model.kit.pads, before)
    }
    @MainActor func testCategoryMatchesAreReservedBeforeFallback() {
        let model = Library()
        model.samples = [Sample(path: "/snare.wav", collection: "Test", category: "Snare")] +
            (0..<20).map { Sample(path: "/kick-\($0).wav", collection: "Test", category: "Kick") }
        model.autoFill()
        XCTAssertEqual(model.kit.pads[2]?.category, "Snare")
        XCTAssertEqual(model.kit.pads.prefix(16).compactMap { $0 }.count, 16)
    }

}
