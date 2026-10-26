import Foundation
import AppKit
import Darwin

let soundTypeNames = ["Kick", "Snare", "Clap", "Closed Hat", "Open Hat", "Tom", "Cymbal", "Percussion", "Bass", "Loops", "Other"]

func soundTypes(in path: String) -> Set<String> {
    func types(_ part: String) -> Set<String> {
        let text = part.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let words = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let rules: [(String, [String])] = [
            ("Loops", ["loops", "loop", "breaks", "patterns", "fills", "songstarter"]),
            ("Kick", ["bass drum", "kick", "kicks", "kik", "bd"]),
            ("Snare", ["snare", "snares", "snr", "sd"]), ("Clap", ["clap", "claps", "clp", "hand clap"]),
            ("Open Hat", ["open hat", "open hi hat", "ohh", "oh"]),
            ("Closed Hat", ["closed hat", "closed hi hat", "chh", "ch"]),
            ("Tom", ["tom", "toms"]), ("Cymbal", ["cymbal", "cymbals", "crash", "ride", "cym"]),
            ("Percussion", ["perc", "percussion", "conga", "bongo", "cowbell", "rim", "rimshot", "shaker", "maracas", "clave", "tamb"]),
            ("Bass", ["bass"])]
        var result = Set(rules.filter { _, tokens in
            tokens.contains { $0.contains(" ") ? text.contains($0) : words.contains($0) }
        }.map { $0.0 })
        if result.contains("Kick") { result.remove("Bass") }
        if !result.contains("Open Hat") && !result.contains("Closed Hat") && !words.isDisjoint(with: ["hihat", "hats", "hat", "hh"]) { result.insert("Closed Hat") }
        return result
    }
    let components = path.split(separator: "/").map(String.init)
    let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var result = types(filename)
    // A nearby sound folder can clarify an ambiguous filename. An unrelated
    // ancestor such as a kit called "Kick ..." must not override a CH filename.
    if result.subtracting(["Loops"]).isEmpty {
        for component in components.dropLast().reversed() {
            let candidate = types(component).subtracting(["Loops"])
            if !candidate.isEmpty { result.formUnion(candidate); break }
        }
    }
    if components.contains(where: { types($0).contains("Loops") }) { result.insert("Loops") }
    return result.isEmpty ? ["Other"] : result
}

func soundTypesForSample(_ path: String) -> Set<String> { soundTypes(in: path) }

func classify(_ path: String) -> String {
    let types = soundTypes(in: path)
    if types.contains("Loops") { return "Loops" }
    return soundTypeNames.first(where: types.contains) ?? "Other"
}

func musicalKey(in name: String) -> String? {
    let pattern = #"(?i)(?<![a-z0-9])([a-g](?:#|b)?)(maj|min|m)(?![a-z0-9])"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
          let noteRange = Range(match.range(at: 1), in: name), let qualityRange = Range(match.range(at: 2), in: name) else { return nil }
    let note = String(name[noteRange]); let quality = name[qualityRange].lowercased()
    return note.prefix(1).uppercased() + note.dropFirst() + (quality == "maj" ? " major" : " minor")
}

struct CollectionNotes {
    var documents: [URL] = []
    var text = ""
    var namingKeys: [String: String] = [:]
    var references: [String: String] = [:]
    static func nameKey(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
        if name.lowercased().hasSuffix(".wav") { name = String(name.dropLast(4)) }
        return name.precomposedStringWithCanonicalMapping.lowercased()
    }
    func details(for sample: Sample) -> String {
        var details: [String] = []
        if let reference = references[Self.nameKey(sample.name)] { details.append(reference) }
        // The 808 documentation explicitly defines the A/B/C accent code.
        // Only expand that positional code when all three accent rules exist;
        // do not treat arbitrary letters or pack prose as per-sample metadata.
        let hasAccentLegend = ["A", "B", "C"].allSatisfy { namingKeys[$0]?.localizedCaseInsensitiveContains("accent") == true }
        let words = sample.name.split(separator: " ")
        if hasAccentLegend, words.count > 1, let accent = namingKeys[String(words[1])], ["A", "B", "C"].contains(String(words[1])) {
            details.append("Accent: " + accent)
        }
        return details.joined(separator: " · ")
    }
    mutating func add(text: String, url: URL, sampleNames: Set<String>) {
        documents.append(url); self.text += "\n" + text
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, parts[0].count <= 24, !parts[1].isEmpty, parts[1].count <= 160 {
                namingKeys[parts[0]] = parts[1]
            }
        }
        guard url.lastPathComponent.localizedCaseInsensitiveContains("reference") else { return }
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let key = Self.nameKey(line)
            guard sampleNames.contains(key) else { continue }
            var details: [String] = []
            for following in lines.dropFirst(index + 1).prefix(6) {
                let trimmed = following.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || sampleNames.contains(Self.nameKey(trimmed)) { break }
                details.append(trimmed)
            }
            if !details.isEmpty { references[key] = details.joined(separator: " · ") }
        }
    }
}

struct LibraryIndex {
    var samples: [Sample]
    var notes: [String: CollectionNotes]
    var documentCount: Int { notes.values.reduce(0) { $0 + $1.documents.count } }

    static func scan(_ requestedRoot: URL) -> LibraryIndex {
        // Enumeration can expand /var to /private/var (and other symlinks).
        // Canonicalize once so relative collection paths use the same prefix.
        var rootPath = requestedRoot.path
        if let resolved = rootPath.withCString({ Darwin.realpath($0, nil) }) {
            rootPath = String(cString: resolved)
            free(resolved)
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return LibraryIndex(samples: [], notes: [:]) }
        let singlePack = fm.fileExists(atPath: root.appendingPathComponent("Docs").path)
        func collection(_ url: URL) -> String {
            let relative = String(url.path.dropFirst(rootPath.count + 1)).split(separator: "/")
            return singlePack || relative.count < 2 ? root.lastPathComponent : String(relative[0])
        }
        var samples: [Sample] = []
        var documents: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let ext = url.pathExtension.lowercased()
            if ["wav", "aif", "aiff", "mp3", "flac", "ogg", "snd"].contains(ext) {
                let relative = String(url.path.dropFirst(rootPath.count + 1))
                let tags = soundTypes(in: relative)
                let name = url.deletingPathExtension().lastPathComponent
                samples.append(Sample(path: url.path, collection: collection(url), category: classify(relative),
                                      tags: tags.sorted(), musicalKey: musicalKey(in: name)))
            } else if ext == "rtf" {
                let relative = String(url.path.dropFirst(rootPath.count + 1)).lowercased()
                if !relative.contains("install") && !relative.contains("coupon") { documents.append(url) }
            }
        }
        let names = Dictionary(grouping: samples, by: \.collection).mapValues { Set($0.map { CollectionNotes.nameKey($0.name) }) }
        var notes: [String: CollectionNotes] = [:]
        for url in documents.sorted(by: { $0.path < $1.path }) {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
                  let data = try? Data(contentsOf: url),
                  let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string else { continue }
            let pack = collection(url)
            var entry = notes[pack] ?? CollectionNotes()
            entry.add(text: text, url: url, sampleNames: names[pack] ?? [])
            notes[pack] = entry
        }
        return LibraryIndex(samples: samples.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, notes: notes)
    }
}

struct SoundQuery {
    let terms: [(String, Bool)]
    init(_ text: String) {
        let regex = try! NSRegularExpression(pattern: #"(-?)(?:"([^"]+)"|(\S+))"#)
        terms = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let range = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            guard let valueRange = Range(range, in: text), let signRange = Range(match.range(at: 1), in: text) else { return nil }
            return (String(text[valueRange]), text[signRange] == "-")
        }
    }
    func matches(_ sample: Sample, notes: CollectionNotes?, includeCollectionNotes: Bool) -> Bool {
        guard !terms.isEmpty else { return true }
        let reference = notes?.details(for: sample) ?? ""
        let text = [sample.path, sample.category, sample.soundTypes.sorted().joined(separator: " "), sample.musicalKey ?? "", reference, includeCollectionNotes ? notes?.text ?? "" : ""].joined(separator: " ")
        return terms.allSatisfy { term, excluded in
            let aliases = ["kicks": "Kick", "kick": "Kick", "loops": "Loops", "loop": "Loops", "snares": "Snare", "claps": "Clap"]
            let found: Bool
            if let type = aliases[term.lowercased()] { found = sample.soundTypes.contains(type) }
            else { found = text.localizedCaseInsensitiveContains(term) }
            return excluded ? !found : found
        }
    }
}
