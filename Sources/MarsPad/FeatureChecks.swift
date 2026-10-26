import Foundation
import AppKit

@MainActor func runFeatureChecks() throws {
    // Legacy plans decode with the new metadata fields absent.
    let legacy = try JSONDecoder().decode(Sample.self, from: Data(#"{"path":"/old/CH.wav","collection":"Old","category":"Closed Hat"}"#.utf8))
    precondition(legacy.tags == nil && legacy.musicalKey == nil)
    precondition(soundTypes(in: "Kick Pack/Closed Hats/CH Combo.wav") == ["Closed Hat"])
    precondition(soundTypes(in: "808 Loops/BD loop 120.wav").isSuperset(of: ["Kick", "Loops"]))
    precondition(musicalKey(in: "Synth Indie F#m 120") == "F# minor")
    precondition(musicalKey(in: "BD A 808 Decay F 04") == nil)

    let model = Library()
    let kick = Sample(path: "/Pack/BD A 808.wav", collection: "Pack", category: "Kick")
    let loop = Sample(path: "/Pack/Loops/BD loop.wav", collection: "Pack", category: "Loops")
    let hat = Sample(path: "/Pack/CH Hat.wav", collection: "Pack", category: "Closed Hat")
    model.samples = [kick, loop, hat]
    model.excludedTypes = ["Kick"]
    precondition(model.filtered == [hat])
    model.excludedTypes = ["Loops"]
    precondition(model.filtered == [kick, hat])
    model.excludedTypes = []
    model.query = "-kicks -loops"
    precondition(model.filtered == [hat])
    model.query = ""
    model.shortcut(.sample(1)); precondition(model.selected == kick.id)
    model.shortcut(.sample(1)); precondition(model.selected == loop.id)
    model.shortcut(.sample(-1)); precondition(model.selected == kick.id)
    model.shortcut(.bank(7)); model.pad = 15; model.shortcut(.assign)
    precondition(model.kit.pads[127] == kick && model.kit.pads[0] == nil)
    model.shortcut(.pad(0, 1)); precondition(model.pad == 15)
    model.shortcut(.pad(1, 0)); precondition(model.pad == 15)
    model.shortcut(.pad(-1, 0)); precondition(model.pad == 14 && model.kit.pads[127] == kick)
    model.shortcut(.pad(0, -1)); precondition(model.pad == 10)
    model.pad = 0; model.shortcut(.pad(0, 1)); precondition(model.pad == 4)
    model.pad = 15; model.shortcut(.clear); precondition(model.kit.pads[127] == nil)

    precondition(PadShortcut.action(characters: "w", keyCode: 13, modifiers: [], editing: false) == .sample(-1))
    precondition(PadShortcut.action(characters: "s", keyCode: 1, modifiers: [], editing: false) == .sample(1))
    precondition(PadShortcut.action(characters: "d", keyCode: 2, modifiers: [], editing: false) == .preview)
    precondition(PadShortcut.action(characters: "a", keyCode: 0, modifiers: [], editing: false) == .stop)
    precondition(PadShortcut.action(characters: " ", keyCode: 49, modifiers: [], editing: false) == .assign)
    precondition(PadShortcut.action(characters: "8", keyCode: 28, modifiers: [], editing: false) == .bank(7))
    precondition(PadShortcut.action(characters: "", keyCode: 126, modifiers: [], editing: false) == .pad(0, 1))
    precondition(PadShortcut.action(characters: "", keyCode: 125, modifiers: [], editing: false) == .pad(0, -1))
    precondition(PadShortcut.action(characters: "s", keyCode: 1, modifiers: [.command], editing: false) == nil)
    precondition(PadShortcut.action(characters: " ", keyCode: 49, modifiers: [], editing: true) == nil)
    precondition(PadShortcut.action(characters: "s", keyCode: 1, modifiers: [], editing: true) == nil)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = root.appendingPathComponent("Pack")
    let docs = pack.appendingPathComponent("Docs")
    let sounds = pack.appendingPathComponent("WAV")
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
    for name in ["BD A 808", "BD B 808", "Songstarter Test F#m 120"] {
        try Data().write(to: sounds.appendingPathComponent(name + ".wav"))
    }
    func rtf(_ text: String, name: String) throws {
        let string = NSAttributedString(string: text)
        let data = try string.data(from: NSRange(location: 0, length: string.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: docs.appendingPathComponent(name + ".rtf"))
    }
    try rtf("A = No Accent\nB = Accent\nC = More Accent\nTape machine", name: "About")
    try rtf("Songstarter Test F#m 120\nF#m, C#m\n", name: "Reference")
    try rtf("Do not index installation instructions", name: "Installation")
    let index = LibraryIndex.scan(root)
    precondition(index.samples.count == 3 && index.documentCount == 2)
    precondition(index.notes["Pack"]?.references.count == 1, "Reference parse: \(index.notes)")
    let notes = index.notes["Pack"]!
    let bass = index.samples.first { $0.name == "BD A 808" }!
    precondition(notes.details(for: bass).contains("No Accent"))
    precondition(SoundQuery(#""No Accent""#).matches(bass, notes: notes, includeCollectionNotes: false))
    let accented = index.samples.first { $0.name == "BD B 808" }!
    precondition(!SoundQuery(#""No Accent""#).matches(accented, notes: notes, includeCollectionNotes: false))
    let song = index.samples.first { $0.name.hasPrefix("Songstarter") }!
    precondition(song.musicalKey == "F# minor" && song.soundTypes.contains("Loops"))
    precondition(SoundQuery("C#m").matches(song, notes: notes, includeCollectionNotes: false))
    precondition(!SoundQuery("Tape").matches(song, notes: notes, includeCollectionNotes: false))
    precondition(SoundQuery("Tape").matches(song, notes: notes, includeCollectionNotes: true))
    model.samples = index.samples; model.collectionNotes = index.notes; model.keyFilter = "F# minor"
    precondition(model.filtered == [song])
    print("PASS: revised keyboard mappings, pad navigation/bounds, text-entry guards, legacy plans, exclusions, filename keys, RTF notes/reference and scoped accent metadata")
}
