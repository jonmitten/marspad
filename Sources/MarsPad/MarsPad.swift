import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct Sample: Identifiable, Codable, Hashable {
    var path: String
    var collection: String
    var category: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}
struct Kit: Codable {
    var version = 1
    var name = "Untitled Kit"
    var pads: [Sample?] = Array(repeating: nil, count: 128)
}
func classify(_ path: String) -> String {
    let text = path.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    let rules: [(String, [String])] = [
        ("Loops", ["loops", "loop", "breaks"]), ("Kick", ["kick", "kicks", "kik", "bd"]),
        ("Snare", ["snare", "snares", "snr", "sd"]), ("Clap", ["clap", "claps", "clp"]),
        ("Open Hat", ["open hat", "open hats", "ohh", "oh"]),
        ("Closed Hat", ["closed hat", "closed hats", "hihat", "hi hat", "hats", "hat", "chh", "hh"]),
        ("Tom", ["tom", "toms"]), ("Cymbal", ["cymbal", "cymbals", "crash", "ride", "cym"]),
        ("Percussion", ["perc", "percussion", "conga", "bongo", "cowbell", "rim", "shaker", "tamb"]),
        ("Bass", ["bass"])]
    let words = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    for (category, tokens) in rules {
        if tokens.contains(where: { $0.contains(" ") ? text.contains($0) : words.contains($0) }) { return category }
    }
    return "Other"
}

func scanFiles(_ root: URL) -> [Sample] {
                let fm = FileManager.default
                guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
                var result: [Sample] = []
                for case let url as URL in e {
                    guard ["wav", "aif", "aiff", "mp3", "flac", "ogg", "snd"].contains(url.pathExtension.lowercased()),
                          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let relative = String(url.path.dropFirst(root.path.count + 1))
                    let parts = relative.split(separator: "/")
                    result.append(Sample(path: url.path, collection: parts.count > 1 ? String(parts[0]) : root.lastPathComponent, category: classify(relative)))
                }
                return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
}

@MainActor final class Library: ObservableObject {
    @Published var samples: [Sample] = []
    @Published var kit = Kit()
    @Published var query = ""
    @Published var collection = "All collections"
    @Published var category = "All sounds"
    @Published var selected: String?
    @Published var bank = 0
    @Published var pad = 0
    @Published var status = "Choose your sample folder to get started."
    @Published var scanning = false
    @Published var exporting = false
    @Published var dirty = false
    @Published var playing: String?
    @Published var sampleDetails = "Select a sample to see its audio details."
    @Published var detailName: String?
    private var detailTask: Task<Void, Never>?
    private var previewID = UUID()
    // AVPlayer opens and buffers media asynchronously instead of decoding the
    // whole sample on the interface thread. Reuse one player for every selection.
    private let player: AVPlayer = {
        let player = AVPlayer()
        player.volume = 0.65
        player.automaticallyWaitsToMinimizeStalling = false
        return player
    }()
    private var previewObservation: NSKeyValueObservation?
    var filtered: [Sample] {
        samples.filter { (collection == "All collections" || $0.collection == collection) && (category == "All sounds" || $0.category == category) && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)) }
    }
    var collections: [String] { ["All collections"] + Set(samples.map(\.collection)).sorted() }
    var categories: [String] { ["All sounds"] + Set(samples.map(\.category)).sorted() }
    var current: Sample? { samples.first { $0.id == selected } }
    var index: Int { bank * 16 + pad }
    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Select an extracted sample library. Files are read without changing them."
        if p.runModal() == .OK, let url = p.url { scan(url) }
    }
    func scan(_ root: URL) {
        guard !scanning else { return }
        scanning = true; status = "Scanning sample names…"
        UserDefaults.standard.set(root.path, forKey: "libraryRoot")
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [Sample] in
                scanFiles(root)
            }.value
            samples = found; scanning = false; collection = "All collections"; category = "All sounds"
            status = "\(found.count.formatted()) audio files indexed. Originals stay in place."
        }
    }
    func preview(_ sample: Sample?) {
        stopPreview()
        guard let sample else { return }
        let requestID = previewID
        detailName = sample.name
        sampleDetails = "Reading audio details…"
        detailTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SampleDetails.read(URL(fileURLWithPath: sample.path)) }
            }.value
            guard !Task.isCancelled, let self, self.previewID == requestID else { return }
            switch result {
            case .success(let details): self.sampleDetails = details.summary
            case .failure: self.sampleDetails = "Audio details unavailable for this file."
            }
        }
        let item = AVPlayerItem(url: URL(fileURLWithPath: sample.path))
        previewObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.playing = nil
                    self.status = "Preview unavailable: \(item.error?.localizedDescription ?? "Unsupported audio file")"
                }
            }
        }
        player.replaceCurrentItem(with: item)
        playing = sample.name
        status = "Preview: \(sample.name)"
        player.play()
    }
    func stopPreview() {
        // Detach the old item before creating its replacement; stale loads and
        // callbacks cannot restart it or overwrite the latest selection's status.
        previewID = UUID()
        detailTask?.cancel()
        detailTask = nil
        detailName = nil
        sampleDetails = "Select a sample to see its audio details."
        previewObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playing = nil
    }
    func assign(_ sample: Sample?, at target: Int? = nil) {
        guard let sample else { return }
        kit.pads[target ?? index] = sample; dirty = true
    }
    func clearBank() {
        let range = (bank * 16)..<(bank * 16 + 16)
        let count = kit.pads[range].compactMap { $0 }.count
        guard count > 0 else { return }
        for index in range { kit.pads[index] = nil }
        stopPreview()
        dirty = true
        status = "Cleared \(count) pads in bank \(String(UnicodeScalar(65 + bank)!)). Other banks unchanged."
    }
    func autoFill() {
        let available = filtered
        var used = Set(kit.pads.compactMap { $0?.path })
        let layout = ["Kick", "Kick", "Snare", "Clap", "Closed Hat", "Closed Hat", "Open Hat", "Percussion", "Tom", "Tom", "Cymbal", "Percussion", "Bass", "Other", "Loops", "Other"]
        var filled = 0
        for n in 0..<16 where kit.pads[bank * 16 + n] == nil {
            if let s = available.first(where: { $0.category == layout[n] && !used.contains($0.path) }) {
                kit.pads[bank * 16 + n] = s; used.insert(s.path); filled += 1
            }
        }
        // Reserve category matches first, then use other filtered sounds for remaining pads.
        var remaining = available.filter { !used.contains($0.path) }.makeIterator()
        for n in 0..<16 where kit.pads[bank * 16 + n] == nil {
            while let candidate = remaining.next() {
                guard used.insert(candidate.path).inserted else { continue }
                kit.pads[bank * 16 + n] = candidate
                filled += 1
                break
            }
        }
        dirty = dirty || filled > 0
        let empty = kit.pads[(bank * 16)..<(bank * 16 + 16)].filter { $0 == nil }.count
        status = "Filled \(filled) empty pads in bank \(String(UnicodeScalar(65 + bank)!)). Existing assignments kept."
        if empty > 0 {
            status += " \(empty) still empty: no more unused sounds match your filters. Broaden filters or choose another collection."
        }
    }
    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let a = NSAlert(); a.messageText = "Discard unsaved kit changes?"; a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Discard")
        return a.runModal() == .alertSecondButtonReturn
    }
    func newKit() { if confirmDiscard() { kit = Kit(); dirty = false } }
    func save() {
        let p = NSSavePanel(); p.nameFieldStringValue = kit.name + ".marspad"
        if p.runModal() == .OK, let url = p.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(kit).write(to: url, options: .atomic); dirty = false; status = "Kit saved: \(url.lastPathComponent)" }
            catch { status = "Save failed: \(error.localizedDescription)" }
        }
    }
    func openKit() {
        guard confirmDiscard() else { return }
        let p = NSOpenPanel(); p.allowedContentTypes = [.json, UTType(filenameExtension: "marspad") ?? .data]
        if p.runModal() == .OK, let url = p.url {
            do {
                let loaded = try JSONDecoder().decode(Kit.self, from: Data(contentsOf: url))
                guard loaded.version == 1, loaded.pads.count == 128 else { throw CocoaError(.fileReadCorruptFile) }
                kit = loaded; dirty = false
                let missing = kit.pads.compactMap { $0 }.filter { !FileManager.default.fileExists(atPath: $0.path) }.count
                status = missing == 0 ? "Kit opened." : "Kit opened; \(missing) assigned files are missing."
            } catch { status = "Open failed: \(error.localizedDescription)" }
        }
    }
    func chooseNativeTemplate() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "xpj") ?? .data]
        panel.message = "Choose a project saved by your MPC Sample (.xpj or a ZIP containing one). It is read as a template and stays unchanged."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: "nativeTemplate")
        return url
    }
    func exportNative() {
        guard !exporting else { return }
        guard kit.pads.contains(where: { $0 != nil }) else { status = "Assign at least one sample before exporting."; return }
        let remembered = UserDefaults.standard.string(forKey: "nativeTemplate").flatMap {
            FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }
        guard let template = remembered ?? chooseNativeTemplate() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = "Choose an export destination. A new folder will contain the .xpj and companion audio directory. Hardware validation is pending."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let snapshot = kit
        exporting = true; status = "Preparing MPC Sample project…"
        Task { [self] in
            let result = await Task.detached(priority: .userInitiated) { [weak self] in
                Result { try NativeExport.export(kit: snapshot, templateURL: template, parent: parent) { message in
                    Task { @MainActor [weak self] in if self?.exporting == true { self?.status = message } }
                } }
            }.value
            exporting = false
            switch result {
            case .success(let folder):
                status = "MPC project exported. Structural checks passed; hardware validation pending."
                NSWorkspace.shared.open(folder)
            case .failure(let error): status = "MPC export failed: \(error.localizedDescription)"
            }
        }
    }
    func exportAudio() {
        let assigned = kit.pads.enumerated().compactMap { i, s in s.map { (i, $0) } }
        guard !assigned.isEmpty else { status = "Assign at least one sample before exporting."; return }
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.message = "Choose a destination. A new folder will contain sample copies and a pad map, not a native MPC project."
        guard p.runModal() == .OK, let parent = p.url else { return }
        let dest = parent.appendingPathComponent("MarsPad-" + UUID().uuidString.prefix(8))
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            var map = "Bank,Pad,File,Original\n"
            func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            for (i,s) in assigned {
                let bankName = String(UnicodeScalar(65 + i / 16)!)
                let source = URL(fileURLWithPath: s.path)
                let filename = String(format: "%@%02d-", bankName, i % 16 + 1) + source.lastPathComponent
                try FileManager.default.copyItem(at: source, to: dest.appendingPathComponent(filename))
                map += "\(bankName),\(i % 16 + 1),\(csv(filename)),\(csv(s.path))\n"
            }
            try map.write(to: dest.appendingPathComponent("Pad Map.csv"), atomically: true, encoding: .utf8)
            try "Sample copies and a human-readable pad map. This is NOT a native MPC Sample project. Audio is copied unchanged; verify supported formats before importing. Pad assignments must be applied on the device.\n".write(to: dest.appendingPathComponent("READ ME.txt"), atomically: true, encoding: .utf8)
            status = "Exported \(assigned.count) sample copies and pad map. Native project export is pending validation."
            NSWorkspace.shared.open(dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            status = "Export failed; incomplete output removed: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject var model = Library()
    let grid = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text("MARS / PAD").font(.system(size: 24, weight: .black, design: .monospaced)); Text("Your sounds. Your banks.").foregroundStyle(.secondary) }
                Spacer()
                Button("Choose Library…", action: model.chooseFolder).disabled(model.scanning)
                Button("Open Kit…", action: model.openKit)
                Button("Save Kit…", action: model.save).keyboardShortcut("s")
                Button("Export Audio…", action: model.exportAudio).disabled(model.exporting)
                Button(model.exporting ? "Exporting…" : "Export MPC…", action: model.exportNative)
                    .disabled(model.exporting)
                    .contextMenu { Button("Change MPC Template…") { _ = model.chooseNativeTemplate() } }
            }.padding(22)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SAMPLE LIBRARY").font(.caption.bold()).foregroundStyle(.secondary)
                    TextField("Search names and folders", text: $model.query).textFieldStyle(.roundedBorder)
                    Picker("Collection", selection: $model.collection) { ForEach(model.collections, id: \.self) { Text($0) } }.labelsHidden()
                    Picker("Sound", selection: $model.category) { ForEach(model.categories, id: \.self) { Text($0) } }.labelsHidden()
                    HStack { Text("\(model.filtered.count.formatted()) sounds").font(.caption); Spacer(); Button("▶ Preview") { model.preview(model.current) }.disabled(model.current == nil) }
                    List(selection: $model.selected) {
                        ForEach(model.filtered) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.name).lineLimit(1)
                                Text("\(s.category) · \(s.collection)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 3).tag(s.id)
                            .onDrag { NSItemProvider(object: s.path as NSString) }
                            .contextMenu { Button("Preview") { model.preview(s) }; Button("Assign to selected pad") { model.assign(s) }; Button("Show in Finder") { NSWorkspace.shared.selectFile(s.path, inFileViewerRootedAtPath: "") } }
                        }
                    }.listStyle(.inset).onChange(of: model.selected) { _ in model.preview(model.current) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.detailName ?? "SAMPLE DETAILS").font(.caption.bold()).lineLimit(1)
                        Text(model.sampleDetails).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }.padding(18).frame(minWidth: 300, idealWidth: 370)
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("Kit name", text: $model.kit.name).font(.title2.bold()).onChange(of: model.kit.name) { _ in model.dirty = true }
                        if model.dirty { Text("Unsaved").font(.caption).foregroundStyle(.orange) }
                        Button("New", action: model.newKit)
                    }
                    HStack(spacing: 7) {
                        ForEach(0..<8) { b in Button(String(UnicodeScalar(65+b)!)) { model.bank = b }.buttonStyle(.borderedProminent).tint(model.bank == b ? .orange : .gray.opacity(0.35)) }
                        Spacer()
                        Button("Clear Bank \(String(UnicodeScalar(65 + model.bank)!))", action: model.clearBank)
                            .disabled(!model.kit.pads[(model.bank * 16)..<(model.bank * 16 + 16)].contains { $0 != nil })
                            .help("Clear all 16 pad assignments in the selected bank")
                        Text("\(model.kit.pads.compactMap { $0 }.count)/128").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: grid, spacing: 10) {
                        ForEach([12,13,14,15,8,9,10,11,4,5,6,7,0,1,2,3], id: \.self) { n in
                            let idx = model.bank * 16 + n
                            let s = model.kit.pads[idx]
                            Button { model.pad = n; model.preview(s) } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack { Text(String(format: "%@%02d", String(UnicodeScalar(65+model.bank)!), n+1)).font(.caption.monospaced().bold()); Spacer(); if s != nil { Image(systemName: "waveform") } }
                                    Text(s?.name ?? "Empty pad").font(.system(size: 12, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Spacer(minLength: 0)
                                    Text(s?.category ?? "Drop a sample").font(.system(size: 10)).foregroundStyle(.secondary)
                                }.padding(12).frame(height: 92).frame(maxWidth: .infinity)
                                .background(model.pad == n ? Color.orange.opacity(0.22) : Color.white.opacity(s == nil ? 0.025 : 0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.pad == n ? Color.orange : Color.white.opacity(0.1), lineWidth: model.pad == n ? 2 : 1))
                            }.buttonStyle(.plain)
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                guard let provider = providers.first else { return false }
                                _ = provider.loadObject(ofClass: String.self) { path, _ in
                                    Task { @MainActor in if let s = model.samples.first(where: { $0.path == path }) { model.assign(s, at: idx) } }
                                }; return true
                            }
                            .contextMenu { Button("Clear pad") { model.kit.pads[idx] = nil; model.dirty = true }; if let s { Button("Show in Finder") { NSWorkspace.shared.selectFile(s.path, inFileViewerRootedAtPath: "") } } }
                        }
                    }
                    HStack {
                        Button("Assign Selected Sound") { model.assign(model.current) }.disabled(model.current == nil)
                        Button("Clear Pad") { model.kit.pads[model.index] = nil; model.dirty = true }
                        Spacer()
                        Button("Auto-fill Empty Pads", action: model.autoFill).tint(.orange)
                    }
                    Text("Auto-fill fills this bank using your filters. Preferred sound types go first, then other unused sounds. Existing pads stay unchanged.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Label("MPC export writes a native project using your device-saved template. Hardware validation is pending; test a separate project first.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }.padding(22).frame(minWidth: 570)
            }
            Divider()
            HStack { if model.scanning { ProgressView().controlSize(.small) }; Text(model.status).font(.caption).lineLimit(2); Spacer(); Text(BuildInfo.footer).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled); Button("Stop Preview", action: model.stopPreview) }.padding(12)
        }.frame(minWidth: 1000, minHeight: 800).preferredColorScheme(.dark)
        .onAppear {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            let args = CommandLine.arguments
            let supplied = args.firstIndex(of: "--library").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            if let root = supplied ?? UserDefaults.standard.string(forKey: "libraryRoot") { model.scan(URL(fileURLWithPath: root)) }
        }
    }
}
@main struct MarsPadApp: App {
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--export-mpc"), CommandLine.arguments.count == index + 4 {
            do {
                let kit = try JSONDecoder().decode(Kit.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
                let folder = try NativeExport.export(kit: kit, templateURL: URL(fileURLWithPath: CommandLine.arguments[index + 2]),
                                                     parent: URL(fileURLWithPath: CommandLine.arguments[index + 3]))
                print(folder.path)
                exit(0)
            } catch { fputs("Export failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--preview-self-test") {
            let model = Library()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            buffer.floatChannelData![0].initialize(repeating: 0, count: 44100)
            let long = folder.appendingPathComponent("long.wav")
            let short = folder.appendingPathComponent("short.wav")
            do {
                let file = try AVAudioFile(forWriting: long, settings: format.settings)
                for _ in 0..<180 { try file.write(from: buffer) }
                let shortFile = try AVAudioFile(forWriting: short, settings: format.settings)
                try shortFile.write(from: buffer)
            } catch { fatalError("Fixture creation failed: \(error)") }
            let details = try! SampleDetails.read(long)
            precondition(abs(details.duration! - 180) < 0.01)
            precondition(details.bitDepth == 32 && details.bitRate == 1411200)
            precondition(details.channels == 1 && details.sampleRate == 44100)
            print("PASS: header metadata for generated 180-second, 32-bit, 44.1 kHz mono WAV (1411.2 kb/s)")
            let start = Date()
            for n in 0..<20 {
                model.preview(Sample(path: (n.isMultiple(of: 2) ? long : short).path, collection: "Test", category: "Other"))
            }
            let elapsed = Date().timeIntervalSince(start)
            precondition(model.playing == "short")
            model.stopPreview()
            precondition(model.playing == nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            precondition(model.playing == nil)
            print("PASS: 20 rapid preview replacements (including 3-minute audio) in \(String(format: "%.3f", elapsed))s; newest selection wins; stop remains stopped")
            exit(0)
        }
        if CommandLine.arguments.contains("--self-test") {
            precondition(classify("808/WAV/01_Kick/kick_001.wav") == "Kick")
            precondition(classify("606/Open Hats/OH_02.wav") == "Open Hat")
            precondition(classify("808 Loops From Mars/BD_loop.wav") == "Loops")
            precondition(classify("Synth/Orbit.wav") == "Other")
            precondition(classify("Drums/SD_01.wav") == "Snare")
            var kit = Kit()
            kit.pads[127] = Sample(path: "/library/café/hat.wav", collection: "café", category: "Closed Hat")
            let restored = try! JSONDecoder().decode(Kit.self, from: JSONEncoder().encode(kit))
            precondition(restored.pads.count == 128 && restored.pads[127] == kit.pads[127] && restored.pads[0] == nil)
            let m = Library()
            let first = Sample(path: "/one/kick.wav", collection: "One", category: "Kick")
            let second = Sample(path: "/two/snare.wav", collection: "Two", category: "Snare")
            m.samples = [first, second]; m.kit.pads[0] = first; m.collection = "Two"; m.autoFill()
            precondition(m.kit.pads[0] == first && m.kit.pads[2] == second && m.kit.pads.compactMap { $0 }.count == 2)
            let kicks = (0..<20).map { Sample(path: "/kicks/kick-\($0).wav", collection: "Kicks", category: "Kick") }
            m.kit = Kit(); m.samples = kicks; m.collection = "All collections"; m.category = "Kick"; m.autoFill()
            precondition(m.kit.pads.prefix(16).compactMap { $0 }.count == 16)
            precondition(Set(m.kit.pads.compactMap { $0?.path }).count == 16)
            let bankA = Array(m.kit.pads.prefix(16))
            m.bank = 7; m.autoFill()
            precondition(Array(m.kit.pads.prefix(16)) == bankA)
            precondition(m.kit.pads.suffix(16).compactMap { $0 }.count == 4)
            precondition(m.status.contains("12 still empty"))
            precondition(Set(m.kit.pads.compactMap { $0?.path }).count == 20)
            let before = m.kit.pads; m.autoFill(); precondition(m.kit.pads == before)
            m.kit = Kit(); m.bank = 0
            m.samples = [Sample(path: "/snare.wav", collection: "Test", category: "Snare")] + kicks
            m.category = "All sounds"; m.autoFill()
            precondition(m.kit.pads[2]?.category == "Snare")
            precondition(m.kit.pads.prefix(16).compactMap { $0 }.count == 16)
            for targetBank in [0, 3, 7] {
                m.kit.pads = Array(repeating: first, count: 128)
                m.bank = targetBank; m.dirty = false
                m.clearBank()
                precondition(m.dirty)
                for i in 0..<128 {
                    precondition((m.kit.pads[i] == nil) == (i / 16 == targetBank))
                }
                m.dirty = false; m.clearBank(); precondition(!m.dirty)
            }
            print("PASS: classification, persistence, filtered fill, full single-category banks, category priority, shortage message, cross-bank duplicate prevention, repeat-fill stability, selected-bank clearing and empty-bank no-op")
            exit(0)
        }
    }
    var body: some Scene { WindowGroup { ContentView() }.commands { CommandGroup(replacing: .newItem) {} } }
}
