import Foundation
import AVFoundation
import AudioToolbox
import Darwin

struct ExportFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct NativeTemplate {
    let header: Data
    let root: [String: Any]
    let layout: NativeJSON
    let trackIndex: Int
    let emptyInstrument: [String: Any]

    static func command(_ executable: String, _ arguments: [String], limit: Int = 32 * 1024 * 1024) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var result = Data()
        while true {
            let part = pipe.fileHandleForReading.readData(ofLength: 65536)
            if part.isEmpty { break }
            result.append(part)
            if result.count > limit {
                process.terminate(); pipe.fileHandleForReading.closeFile(); process.waitUntilExit()
                throw ExportFailure("Project exceeds the supported size limit.")
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportFailure("Could not read or compress the native project.") }
        return result
    }

    static func read(_ url: URL, requireEmptyPad: Bool = true) throws -> NativeTemplate {
        var packed: Data
        if url.pathExtension.lowercased() == "zip" {
            let list = try command("/usr/bin/unzip", ["-Z1", url.path], limit: 4 * 1024 * 1024)
            let names = String(decoding: list, as: UTF8.self).split(separator: "\n").map(String.init)
                .filter { $0.lowercased().hasSuffix(".xpj") && !$0.hasPrefix("__MACOSX/") }
            guard names.count == 1 else { throw ExportFailure("Choose an archive containing exactly one MPC Sample .xpj project.") }
            // Read one member to stdout; never extract archive paths to disk.
            packed = try command("/usr/bin/unzip", ["-p", url.path, names[0]])
        } else {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw ExportFailure("Template is too large.") }
            packed = try Data(contentsOf: url)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gz")
        try packed.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let raw = try command("/usr/bin/gzip", ["-dc", temporary.path])
        guard let marker = raw.firstIndex(of: 123),
              String(decoding: raw[..<marker], as: UTF8.self) == "ACVS\n1.3.0.12\nSerialisableProjectData\njson\nLinux\n",
              let root = try JSONSerialization.jsonObject(with: raw[marker...]) as? [String: Any],
              let data = root["data"] as? [String: Any], data["version"] as? Int == 28,
              data["engineMode"] as? String == "Sample",
              data["lastSavedProductIdentifier"] as? String == "AC50",
              let tracks = data["tracks"] as? [[String: Any]] else {
            throw ExportFailure("Template is not the supported MPC Sample AC50 project format (1.3.0.12 / schema 28).")
        }
        let candidates = tracks.indices.filter { (tracks[$0]["program"] as? [String: Any])?["type"] as? Int == 0 }
        guard candidates.count == 1, let index = candidates.first,
              let program = tracks[index]["program"] as? [String: Any],
              let drum = program["drum"] as? [String: Any],
              let instruments = drum["instruments"] as? [[String: Any]], instruments.count == 128,
              let empty = instruments.last(where: { instrument in
                  guard let layers = instrument["layersv"] as? [[String: Any]], layers.count == 8 else { return false }
                  return layers.allSatisfy {
                      ($0["sampleFile"] as? String)?.isEmpty == true && $0["sliceInfo"] is [String: Any]
                  }
              }) ?? (requireEmptyPad ? nil : instruments.first),
              let sequences = data["sequences"] as? [[String: Any]], !sequences.isEmpty else {
            throw ExportFailure("Template must contain one 128-pad drum track, eight layers per pad, an empty pad, and a sequence.")
        }
        return NativeTemplate(header: Data(raw[..<marker]), root: root, layout: try NativeJSON.parse(Data(raw[marker...])), trackIndex: index, emptyInstrument: empty)
    }
}

enum NativeExport {
    // Remove content and automation recursively while retaining unknown schema fields.
    static func cleaned(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            var result = dictionary
            for (key, value) in dictionary {
                if ["samples", "events", "items", "effects", "arrangementClipMap", "sharedClipMap"].contains(key) {
                    result[key] = [Any]()
                } else if ["sampleFile", "sampleName"].contains(key) {
                    result[key] = ""
                } else if key == "fxValue" { result[key] = 0.0
                } else { result[key] = cleaned(value) }
            }
            return result
        }
        if let array = object as? [Any] { return array.map(cleaned) }
        return object
    }

    static func filename(pad: String, sampleName: String) -> String {
        // Portable filenames for removable media; display names stay intact in XPJ.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-().#[]")
        let safe = sampleName.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        let stem = String(safe.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        return pad + "_" + (stem.isEmpty ? "Sample" : stem) + ".wav"
    }

    static func createExportDirectory(kitName: String, parent: URL) throws -> (String, URL) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-().#[]")
        let sanitized = kitName.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        let stem = String(sanitized.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let name = stem.isEmpty ? "Untitled Kit" : stem
        var number = 1
        while true {
            let base = number == 1 ? name : name + "-" + String(number)
            let destination = parent.appendingPathComponent(base, isDirectory: true)
            // mkdir reserves a fresh name atomically; Foundation's directory
            // creation may succeed for an existing folder, which we must not reuse.
            let result = destination.path.withCString { Darwin.mkdir($0, mode_t(0o755)) }
            if result == 0 { return (base, destination) }
            let code = errno
            if code == EEXIST { number += 1 }
            else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
    }

    static func sampleNames(_ pads: [Sample?]) -> [Int: String] {
        func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
        let counts = Dictionary(grouping: pads.compactMap { $0 }, by: { key($0.name) }).mapValues { $0.count }
        var used = Set<String>()
        var names: [Int: String] = [:]
        for (index, sample) in pads.enumerated() {
            guard let sample else { continue }
            let pad = String(format: "%@%02d", String(UnicodeScalar(65 + index / 16)!), index % 16 + 1)
            var name = counts[key(sample.name)] == 1 ? sample.name : sample.name + " [" + pad + "]"
            var suffix = 2
            while !used.insert(key(name)).inserted {
                name = sample.name + " [" + pad + "-" + String(suffix) + "]"
                suffix += 1
            }
            names[index] = name
        }
        return names
    }

    static func writeAudio(_ source: URL, to destination: URL) throws -> Int64 {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard [44100.0, 48000.0, 96000.0].contains(format.sampleRate),
              (1...2).contains(format.channelCount), input.length > 0,
              Double(input.length) / format.sampleRate <= 1200 else {
            throw ExportFailure("Use mono/stereo audio at 44.1, 48 or 96 kHz, up to 20 minutes per sample: \(source.lastPathComponent)")
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { throw ExportFailure("Could not allocate audio buffer.") }
        var frames: Int64 = 0
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw ExportFailure("Unexpected end of audio: \(source.lastPathComponent)") }
            try output.write(from: buffer)
            frames += Int64(buffer.frameLength)
        }
        guard frames == input.length else { throw ExportFailure("Audio length mismatch: \(source.lastPathComponent)") }
        return frames
    }

    static func export(kit: Kit, templateURL: URL, parent: URL,
                       progress: @escaping (String) -> Void = { _ in }) throws -> URL {
        guard kit.version == 1, kit.pads.count == 128, kit.pads.contains(where: { $0 != nil }) else {
            throw ExportFailure("Assign at least one sample to a valid 128-pad kit.")
        }
        progress("Reading native project template…")
        let template = try NativeTemplate.read(templateURL)
        var data = cleaned(template.root["data"]!) as! [String: Any]
        var tracks = data["tracks"] as! [[String: Any]]
        var track = tracks[template.trackIndex]
        var program = track["program"] as! [String: Any]
        var drum = program["drum"] as! [String: Any]
        let blank = cleaned(template.emptyInstrument) as! [String: Any]
        var instruments = Array(repeating: blank, count: 128)
        var sampleEntries: [[String: Any]] = []
        let (base, destination) = try createExportDirectory(kitName: kit.name, parent: parent)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        let audioFolder = destination.appendingPathComponent(base + "_[ProjectData]")
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: false)
        var map: [[String: Any]] = []
        let displayNames = sampleNames(kit.pads)
        for (index, sample) in kit.pads.enumerated() {
            guard let sample else { continue }
            let name = String(format: "%@%02d", String(UnicodeScalar(65 + index / 16)!), index % 16 + 1)
            let displayName = displayNames[index]!
            let filename = filename(pad: name, sampleName: sample.name)
            progress("Writing \(name): \(sample.name)")
            let audioURL = audioFolder.appendingPathComponent(filename)
            let frames: Int64
            do { frames = try writeAudio(URL(fileURLWithPath: sample.path), to: audioURL) }
            catch { throw ExportFailure("\(name) — \(error.localizedDescription)") }
            let details = try SampleDetails.read(audioURL)
            guard details.bitDepth == 24, !details.compressed else { throw ExportFailure("Output audio validation failed for \(name).") }
            var layers = instruments[index]["layersv"] as! [[String: Any]]
            layers[0]["sampleName"] = displayName
            layers[0]["sampleFile"] = filename
            // The device stores an inclusive last frame in sliceInfo.End.
            var slice = layers[0]["sliceInfo"] as! [String: Any]
            slice["Start"] = 0; slice["End"] = frames - 1
            slice["LoopStart"] = 0; slice["LoopMode"] = 0
            layers[0]["sliceInfo"] = slice
            instruments[index]["layersv"] = layers
            sampleEntries.append(["version": 1, "name": displayName, "path": filename, "loadImpl": 0,
                                  "metadata": ["tempo": 0.0, "rootNote": 60, "tune": 0.0, "key": ""]])
            map.append(["pad": name, "sourceName": sample.name, "sampleName": displayName, "file": filename, "frames": frames,
                        "sampleRate": details.sampleRate, "channels": details.channels])
        }
        drum["instruments"] = instruments
        program["drum"] = drum
        // Preserve track names: sequence maps and routing refer to them by name.
        track["program"] = program; track["samples"] = sampleEntries
        track["volume"] = 1.0; track["mute"] = false; track["transposition"] = 0
        tracks[template.trackIndex] = track
        data["tracks"] = tracks; data["samples"] = sampleEntries
        data["currentSequence"] = 0; data["currentTrackIndex"] = template.trackIndex
        data["currentAssignablePadBank"] = 0
        if var info = data["info"] as? [String: Any] {
            for key in info.keys { info[key] = "" }
            info["title"] = kit.name
            data["info"] = info
        }
        let project = destination.appendingPathComponent(base + ".xpj")
        let raw = template.header + (try template.layout.encode(["data": data]))
        let temporary = destination.appendingPathComponent(".project-raw")
        try raw.write(to: temporary)
        let compressed = try NativeTemplate.command("/usr/bin/gzip", ["-nc", temporary.path])
        try compressed.write(to: project, options: .atomic)
        try FileManager.default.removeItem(at: temporary)
        // Decode the actual written file, not just the in-memory representation.
        let reopened = try NativeTemplate.read(project, requireEmptyPad: false)
        try validate(reopened.root, folder: audioFolder, expected: map)
        let report: [String: Any] = ["kit": kit.name, "format": "MPC Sample AC50", "status": "structural checks passed; hardware validation pending",
                                    "template": templateURL.lastPathComponent, "projectFile": base + ".xpj", "assignments": map]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("Export Report.json"))
        try """
        MPC Sample project export — hardware validation pending.
        Copy \(base).xpj and the matching \(base)_[ProjectData] folder directly into MPC-Sample/Projects on your microSD card, matching the device-created layout. Do not copy this outer export folder. Keep reports and these notes on your computer. Do not replace existing projects; use a different project name if the card already has one with this name. Safely eject before leaving SD Card Access mode.
        Save your current device project before testing. Load this .xpj through the Project menu. Verify A01, A16, B01 and H16 (where assigned), full sample playback, empty pads, and bank order before relying on the export. Do not overwrite your original projects.
        Audio is exported as 24-bit PCM WAV at its original supported sample rate. Source files and template are unchanged. Existing template sequence events, song items and effects are cleared. Routing and other schema defaults are retained.
        """.write(to: destination.appendingPathComponent("READ ME.txt"), atomically: true, encoding: .utf8)
        succeeded = true
        return destination
    }

    static func validate(_ root: [String: Any], folder: URL, expected: [[String: Any]]) throws {
        guard let data = root["data"] as? [String: Any],
              let tracks = data["tracks"] as? [[String: Any]],
              let track = tracks.first(where: { ($0["program"] as? [String: Any])?["type"] as? Int == 0 }),
              let program = track["program"] as? [String: Any],
              let drum = program["drum"] as? [String: Any],
              let instruments = drum["instruments"] as? [[String: Any]], instruments.count == 128 else {
            throw ExportFailure("Generated project has an invalid drum track.")
        }
        var actual: [String: String] = [:]
        for (index, instrument) in instruments.enumerated() {
            guard let layers = instrument["layersv"] as? [[String: Any]], layers.count == 8 else { throw ExportFailure("Invalid layer count.") }
            for layer in layers {
                if let file = layer["sampleFile"] as? String, !file.isEmpty {
                    let pad = String(format: "%@%02d", String(UnicodeScalar(65 + index / 16)!), index % 16 + 1)
                    guard let entry = expected.first(where: { $0["pad"] as? String == pad }),
                          actual[pad] == nil, file == entry["file"] as? String,
                          file.hasPrefix(pad + "_"), !file.contains("/"), !file.contains("\\"),
                          layer["sampleName"] as? String == entry["sampleName"] as? String,
                          FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) else { throw ExportFailure("Invalid or missing sample reference at \(pad).") }
                    actual[pad] = file
                    guard let frames = entry["frames"] as? Int64,
                          let slice = layer["sliceInfo"] as? [String: Any],
                          (slice["End"] as? NSNumber)?.int64Value == frames - 1 else { throw ExportFailure("Invalid sample end frame at \(pad).") }
                }
            }
        }
        guard actual.count == expected.count else { throw ExportFailure("Generated pad count does not match your kit.") }
        for inventory in [data["samples"], track["samples"]] {
            guard let entries = inventory as? [[String: Any]], entries.count == expected.count else { throw ExportFailure("Invalid sample inventory.") }
            for record in expected {
                guard entries.filter({ $0["path"] as? String == record["file"] as? String && $0["name"] as? String == record["sampleName"] as? String }).count == 1 else {
                    throw ExportFailure("Sample name or inventory path did not survive export.")
                }
            }
        }
        var references = Set<String>()
        func walk(_ value: Any) throws {
            if let dict = value as? [String: Any] {
                if let events = dict["events"] as? [Any], !events.isEmpty { throw ExportFailure("Sequence events remain in the export.") }
                for (key, item) in dict {
                    if ["path", "sampleFile"].contains(key), let text = item as? String, !text.isEmpty {
                        guard !text.contains("/"), actual.values.contains(text) else { throw ExportFailure("Unexpected audio path in generated project.") }
                        references.insert(text)
                    }
                    try walk(item)
                }
            } else if let array = value as? [Any] { for item in array { try walk(item) } }
        }
        try walk(data)
        guard references == Set(actual.values) else { throw ExportFailure("Sample references do not match the exported audio.") }
    }
}
