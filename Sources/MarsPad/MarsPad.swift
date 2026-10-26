import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct Sample: Identifiable, Codable, Hashable {
    var path: String
    var collection: String
    var category: String
    var tags: [String]? = nil
    var musicalKey: String? = nil
    var soundTypes: Set<String> { Set(tags ?? Array(soundTypesForSample(path))).union([category]).subtracting(category == "Other" && tags != nil ? ["Other"] : []) }
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}
struct Kit: Codable, Equatable {
    var version = 1
    var name = "Untitled Kit"
    var pads: [Sample?] = Array(repeating: nil, count: 128)
}
struct KitEdit {
    let name: String
    let before: Kit
    var after: Kit
    let bank: Int
    let pad: Int
    let group: UUID?
}

@MainActor final class Library: ObservableObject {
    @Published var samples: [Sample] = [] { didSet { cachedFiltered = nil; cachedCollections = nil; cachedKeys = nil } }
    private var cachedFiltered: [Sample]?
    private var cachedCollections: [String]?
    private var cachedKeys: [String]?
    @Published var kit = Kit()
    @Published private(set) var undoEdits: [KitEdit] = []
    @Published private(set) var redoEdits: [KitEdit] = []
    private var savedKit = Kit()
    private var renameGroup: UUID?
    var canUndo: Bool { !undoEdits.isEmpty }
    var canRedo: Bool { !redoEdits.isEmpty }
    var undoTitle: String { undoEdits.last.map { "Undo " + $0.name } ?? "Undo" }
    var redoTitle: String { redoEdits.last.map { "Redo " + $0.name } ?? "Redo" }
    func commitEdit(_ next: Kit, name: String, target: Int? = nil, group: UUID? = nil) {
        guard next != kit else { return }
        let before = kit
        if let group, var last = undoEdits.last, last.group == group {
            if last.before == next { undoEdits.removeLast() }
            else { last.after = next; undoEdits[undoEdits.count - 1] = last }
        } else {
            undoEdits.append(KitEdit(name: name, before: before, after: next,
                                     bank: target.map { $0 / 16 } ?? bank,
                                     pad: target.map { $0 % 16 } ?? pad, group: group))
            if undoEdits.count > 100 { undoEdits.removeFirst() }
        }
        redoEdits = []
        kit = next
        dirty = kit != savedKit
    }
    func undoKitEdit() {
        guard let edit = undoEdits.popLast() else { return }
        renameGroup = nil
        stopPreview()
        kit = edit.before; bank = edit.bank; pad = edit.pad
        redoEdits.append(edit)
        dirty = kit != savedKit
        status = "Undid " + edit.name + "."
    }
    func redoKitEdit() {
        guard let edit = redoEdits.popLast() else { return }
        renameGroup = nil
        stopPreview()
        kit = edit.after; bank = edit.bank; pad = edit.pad
        undoEdits.append(edit)
        dirty = kit != savedKit
        status = "Redid " + edit.name + "."
    }
    func setNameEditing(_ editing: Bool) { renameGroup = editing ? UUID() : nil }
    func renameKit(_ name: String) {
        var next = kit; next.name = name
        commitEdit(next, name: "Rename Kit", group: renameGroup)
    }
    func markSaved() { savedKit = kit; dirty = false }
    func replaceKit(_ next: Kit) {
        stopPreview(); kit = next; savedKit = next; dirty = false
        undoEdits = []; redoEdits = []; renameGroup = nil
    }
    @Published var query = "" { didSet { cachedFiltered = nil } }
    @Published var collection = "All collections" { didSet { cachedFiltered = nil } }
    @Published var category = "All sounds" { didSet { cachedFiltered = nil } }
    @Published var excludedTypes = Set<String>() { didSet { cachedFiltered = nil } }
    @Published var keyFilter = "All keys" { didSet { cachedFiltered = nil } }
    @Published var searchCollectionNotes = false { didSet { cachedFiltered = nil } }
    @Published var collectionNotes: [String: CollectionNotes] = [:] { didSet { cachedFiltered = nil } }
    @Published var indexedDocuments = 0
    @Published var selected: String?
    @Published var bank = 0
    @Published var pad = 0
    @Published var status = "Choose your sample folder to get started."
    @Published var scanning = false
    @Published var exporting = false
    @Published var customTemplateEnabled = UserDefaults.standard.bool(forKey: "useCustomNativeTemplate")
    @Published var dirty = false
    @Published var playing: String?
    @Published var sampleDetails = "Select a sample to see its audio details."
    @Published var detailName: String?
    @Published var detailPath: String?
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
        if let cachedFiltered { return cachedFiltered }
        let search = SoundQuery(query)
        let result = samples.filter {
            (collection == "All collections" || $0.collection == collection) &&
            (category == "All sounds" || $0.soundTypes.contains(category)) &&
            $0.soundTypes.isDisjoint(with: excludedTypes) &&
            (keyFilter == "All keys" || $0.musicalKey == keyFilter) &&
            search.matches($0, notes: collectionNotes[$0.collection], includeCollectionNotes: searchCollectionNotes)
        }
        cachedFiltered = result
        return result
    }
    var collections: [String] {
        if let cachedCollections { return cachedCollections }
        let result = ["All collections"] + Set(samples.map(\.collection)).sorted()
        cachedCollections = result; return result
    }
    var categories: [String] { ["All sounds"] + soundTypeNames }
    var musicalKeys: [String] {
        if let cachedKeys { return cachedKeys }
        let result = ["All keys"] + Set(samples.compactMap(\.musicalKey)).sorted()
        cachedKeys = result; return result
    }
    var current: Sample? { filtered.first { $0.id == selected } }
    var inspected: Sample? { samples.first { $0.path == detailPath } ?? kit.pads.compactMap { $0 }.first { $0.path == detailPath } }
    var inspectedNotes: CollectionNotes? { inspected.flatMap { collectionNotes[$0.collection] } }
    var referenceDetails: String? {
        guard let sample = inspected, let notes = inspectedNotes else { return nil }
        let details = notes.details(for: sample)
        return details.isEmpty ? nil : details
    }
    func clearPad(at target: Int) {
        guard kit.pads.indices.contains(target), kit.pads[target] != nil else { return }
        var next = kit; next.pads[target] = nil
        let label = String(format: "%@%02d", String(UnicodeScalar(65 + target / 16)!), target % 16 + 1)
        commitEdit(next, name: "Clear " + label, target: target)
        status = "Cleared pad " + label + "."
    }
    func clearSelectedPad() { clearPad(at: index) }
    func shortcut(_ action: PadShortcut) {
        switch action {
        case .undo: undoKitEdit()
        case .redo: redoKitEdit()
        case .assign: assign(current)
        case .clear: clearSelectedPad()
        case .preview: preview(current)
        case .previewPad:
            if let sample = kit.pads[index] { preview(sample) }
            else { stopPreview(); status = "Selected pad is empty." }
        case .stop: stopPreview(); status = "Preview stopped."
        case .bank(let target): bank = min(7, max(0, target))
        case .pad(let horizontal, let vertical):
            let column = min(3, max(0, pad % 4 + horizontal))
            let row = min(3, max(0, pad / 4 + vertical))
            pad = row * 4 + column
        case .sample(let direction):
            let sounds = filtered
            guard !sounds.isEmpty else { return }
            let next = sounds.firstIndex(where: { $0.id == selected }).map { min(sounds.count - 1, max(0, $0 + direction)) } ?? 0
            selected = sounds[next].id
        }
    }
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
            let found = await Task.detached(priority: .userInitiated) { () -> LibraryIndex in
                LibraryIndex.scan(root)
            }.value
            samples = found.samples; collectionNotes = found.notes; indexedDocuments = found.documentCount
            scanning = false; collection = "All collections"; category = "All sounds"
            excludedTypes = []; keyFilter = "All keys"
            status = "\(found.samples.count.formatted()) audio files and \(found.documentCount) information documents indexed. Originals stay in place."
        }
    }
    func preview(_ sample: Sample?) {
        stopPreview()
        guard let sample else {
            detailName = nil; detailPath = nil
            sampleDetails = "Select a sample to see its audio details."
            return
        }
        let requestID = previewID
        detailName = sample.name
        detailPath = sample.path
        sampleDetails = "Reading audio details…"
        detailTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SampleDetails.read(URL(fileURLWithPath: sample.path)) }
            }.value
            guard !Task.isCancelled, let self, self.previewID == requestID else { return }
            switch result {
            case .success(let details): self.sampleDetails = details.summary
            case .failure(let error):
                self.sampleDetails = "Audio details unavailable: \(error.localizedDescription)"
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
        // Keep the last selected file visible for inspection after stopping.
        if sampleDetails == "Reading audio details…" { sampleDetails = "Audio details reading stopped. Select Preview to retry." }
        previewObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playing = nil
    }
    func revealSample() {
        guard let path = detailPath else { return }
        if !NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") {
            status = "Could not reveal file in Finder: \(path)"
        }
    }
    func assign(_ sample: Sample?, at target: Int? = nil) {
        guard let sample else { return }
        let target = target ?? index
        guard kit.pads.indices.contains(target) else { return }
        var next = kit; next.pads[target] = sample
        let label = String(format: "%@%02d", String(UnicodeScalar(65 + target / 16)!), target % 16 + 1)
        commitEdit(next, name: "Assign " + label, target: target)
    }
    func clearBank() {
        let range = (bank * 16)..<(bank * 16 + 16)
        let count = kit.pads[range].compactMap { $0 }.count
        guard count > 0 else { return }
        var next = kit
        for index in range { next.pads[index] = nil }
        commitEdit(next, name: "Clear Bank " + String(UnicodeScalar(65 + bank)!))
        stopPreview()
        status = "Cleared \(count) pads in bank \(String(UnicodeScalar(65 + bank)!)). Other banks unchanged."
    }
    func autoFill() {
        let available = filtered
        var next = kit
        var used = Set(next.pads.compactMap { $0?.path })
        let layout = ["Kick", "Kick", "Snare", "Clap", "Closed Hat", "Closed Hat", "Open Hat", "Percussion", "Tom", "Tom", "Cymbal", "Percussion", "Bass", "Other", "Loops", "Other"]
        var filled = 0
        for n in 0..<16 where next.pads[bank * 16 + n] == nil {
            if let s = available.first(where: { $0.category == layout[n] && !used.contains($0.path) }) {
                next.pads[bank * 16 + n] = s; used.insert(s.path); filled += 1
            }
        }
        // Reserve category matches first, then use other filtered sounds for remaining pads.
        var remaining = available.filter { !used.contains($0.path) }.makeIterator()
        for n in 0..<16 where next.pads[bank * 16 + n] == nil {
            while let candidate = remaining.next() {
                guard used.insert(candidate.path).inserted else { continue }
                next.pads[bank * 16 + n] = candidate
                filled += 1
                break
            }
        }
        if filled > 0 { commitEdit(next, name: "Auto-fill Bank " + String(UnicodeScalar(65 + bank)!)) }
        let empty = next.pads[(bank * 16)..<(bank * 16 + 16)].filter { $0 == nil }.count
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
    func newKit() { if confirmDiscard() { replaceKit(Kit()) } }
    func save() {
        let p = NSSavePanel(); p.nameFieldStringValue = kit.name + ".marspad"
        if p.runModal() == .OK, let url = p.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(kit).write(to: url, options: .atomic); markSaved(); status = "Kit saved: \(url.lastPathComponent)" }
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
                replaceKit(loaded)
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
        customTemplateEnabled = true
        UserDefaults.standard.set(true, forKey: "useCustomNativeTemplate")
        return url
    }
    func useBuiltInTemplate() {
        customTemplateEnabled = false
        UserDefaults.standard.set(false, forKey: "useCustomNativeTemplate")
        status = "MPC export will use the built-in blank project."
    }
    func exportNative() {
        guard !exporting else { return }
        guard kit.pads.contains(where: { $0 != nil }) else { status = "Assign at least one sample before exporting."; return }
        let template: URL?
        if customTemplateEnabled {
            guard let path = UserDefaults.standard.string(forKey: "nativeTemplate"), FileManager.default.fileExists(atPath: path) else {
                status = "Custom template is missing. Right-click Export MPC to use the built-in blank project or choose another template."
                return
            }
            template = URL(fileURLWithPath: path)
        } else { template = nil }
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
                    .contextMenu {
                        Button("Use Built-in Blank Project") { model.useBuiltInTemplate() }
                        Button("Use Custom MPC Template…") { _ = model.chooseNativeTemplate() }
                    }
            }.padding(22)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SAMPLE LIBRARY").font(.caption.bold()).foregroundStyle(.secondary)
                    TextField("Search sounds; use -kick or -loops to exclude", text: $model.query).textFieldStyle(.roundedBorder)
                    Picker("Collection", selection: $model.collection) { ForEach(model.collections, id: \.self) { Text($0) } }.labelsHidden()
                    Picker("Sound", selection: $model.category) { ForEach(model.categories, id: \.self) { Text($0) } }.labelsHidden()
                    HStack {
                        Menu {
                            ForEach(soundTypeNames, id: \.self) { type in
                                Toggle(type, isOn: Binding(get: { model.excludedTypes.contains(type) }, set: { value in
                                    if value { model.excludedTypes.insert(type) } else { model.excludedTypes.remove(type) }
                                }))
                            }
                            Divider()
                            Button("Clear exclusions") { model.excludedTypes = [] }
                        } label: { Text(model.excludedTypes.isEmpty ? "Exclude sounds…" : "Exclude sounds (\(model.excludedTypes.count))") }
                        if model.musicalKeys.count > 1 {
                            Picker("Musical key", selection: $model.keyFilter) { ForEach(model.musicalKeys, id: \.self) { Text($0) } }.labelsHidden()
                        }
                    }
                    if !model.excludedTypes.isEmpty {
                        Text("Excluding: " + model.excludedTypes.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Search collection notes", isOn: $model.searchCollectionNotes)
                        .font(.caption).disabled(model.indexedDocuments == 0)
                        .help("Include pack-level information from RTF documents in searches. These are collection notes, not measured properties of each sample.")
                    HStack { Text("\(model.filtered.count.formatted()) sounds").font(.caption); Spacer(); Button("▶ Preview") { model.preview(model.current) }.disabled(model.current == nil) }
                    ScrollViewReader { scroll in
                    List(selection: $model.selected) {
                        ForEach(model.filtered) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.name).lineLimit(1)
                                Text("\(s.category) · \(s.collection)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 3).tag(s.id)
                            .onDrag { NSItemProvider(object: s.path as NSString) }
                            .contextMenu { Button("Preview") { model.preview(s) }; Button("Assign to selected pad") { model.assign(s) }; Button("Show in Finder") { NSWorkspace.shared.selectFile(s.path, inFileViewerRootedAtPath: "") } }
                        }
                    }.listStyle(.inset).onChange(of: model.selected) { selection in
                        model.preview(model.current)
                        if let selection { scroll.scrollTo(selection) }
                    }
                    .onChange(of: model.collection) { _ in if model.current == nil { model.selected = nil; model.stopPreview() } }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(model.detailName ?? "SAMPLE DETAILS").font(.caption.bold()).lineLimit(1)
                            Spacer()
                            Button("Show in Finder", action: model.revealSample)
                                .disabled(model.detailPath == nil)
                        }
                        Text(model.sampleDetails).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if let sample = model.inspected, let key = sample.musicalKey {
                            Text("Filename key: " + key).font(.caption).foregroundStyle(.secondary)
                        }
                        if let reference = model.referenceDetails {
                            Text("Reference: " + reference).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let notes = model.inspectedNotes, !notes.documents.isEmpty {
                            Menu("Collection Info…") {
                                ForEach(notes.documents, id: \.path) { document in
                                    Button(document.lastPathComponent) { NSWorkspace.shared.open(document) }
                                }
                            }.help(notes.namingKeys.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n"))
                        }
                        if let path = model.detailPath {
                            Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(2).textSelection(.enabled).help(path)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }.padding(18).frame(minWidth: 300, idealWidth: 370)
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("Kit name", text: Binding(get: { model.kit.name }, set: { model.renameKit($0) }), onEditingChanged: model.setNameEditing).font(.title2.bold())
                        if model.dirty { Text("Unsaved").font(.caption).foregroundStyle(.orange) }
                        Button { NSApp.keyWindow?.makeFirstResponder(nil); model.undoKitEdit() } label: { Image(systemName: "arrow.uturn.backward") }
                            .disabled(!model.canUndo).help(model.undoTitle).accessibilityLabel(model.undoTitle)
                        Button { NSApp.keyWindow?.makeFirstResponder(nil); model.redoKitEdit() } label: { Image(systemName: "arrow.uturn.forward") }
                            .disabled(!model.canRedo).help(model.redoTitle).accessibilityLabel(model.redoTitle)
                        Button("New", action: model.newKit)
                    }
                    HStack(spacing: 7) {
                        ForEach(0..<8) { b in Button(String(UnicodeScalar(65+b)!)) { NSApp.keyWindow?.makeFirstResponder(nil); model.bank = b }.buttonStyle(.borderedProminent).tint(model.bank == b ? .orange : .gray.opacity(0.35)) }
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
                            Button { NSApp.keyWindow?.makeFirstResponder(nil); model.pad = n; model.preview(s) } label: {
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
                            .contextMenu { Button("Clear pad") { model.clearPad(at: idx) }; if let s { Button("Show in Finder") { NSWorkspace.shared.selectFile(s.path, inFileViewerRootedAtPath: "") } } }
                        }
                    }
                    HStack {
                        Button("Assign Selected Sound (Space)") { NSApp.keyWindow?.makeFirstResponder(nil); model.assign(model.current) }.disabled(model.current == nil)
                        Button("Clear Pad (C)") { NSApp.keyWindow?.makeFirstResponder(nil); model.clearSelectedPad() }
                        Spacer()
                        Button("Auto-fill Empty Pads") { NSApp.keyWindow?.makeFirstResponder(nil); model.autoFill() }.tint(.orange)
                    }
                    Text("W/S: samples · D: sample · F: pad · A: stop · Arrows: pads · 1–8: banks · Space: assign · C: clear · ⌘Z: undo · ⌘⇧Z: redo. Shortcuts pause while typing. Auto-fill respects your filters and exclusions.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Label("Export MPC creates a project with your kit name and pad assignments. A blank project is built in; a custom template is optional.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }.padding(22).frame(minWidth: 570)
            }
            Divider()
            HStack { if model.scanning { ProgressView().controlSize(.small) }; Text(model.status).font(.caption).lineLimit(2); Spacer(); Text(BuildInfo.footer).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled); Button("Stop Preview", action: model.stopPreview) }.padding(12)
        }.frame(minWidth: 1000, minHeight: 800).preferredColorScheme(.dark)
        .background(PadKeyboardShortcuts { model.shortcut($0) })
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
        if let index = CommandLine.arguments.firstIndex(of: "--scan-library"), CommandLine.arguments.count == index + 2 {
            let library = LibraryIndex.scan(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            print("Indexed \(library.samples.count) audio files, \(library.documentCount) information documents, \(library.notes.values.reduce(0) { $0 + $1.references.count }) filename reference entries")
            let accents = library.samples.filter { library.notes[$0.collection]?.details(for: $0).contains("Accent:") == true }.count
            print("Samples with documented accent metadata: \(accents)")
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--roundtrip-native"), CommandLine.arguments.count == index + 3 {
            do {
                let templateURL = try CommandLine.arguments[index + 1] == "builtin" ? NativeTemplate.builtInURL() : URL(fileURLWithPath: CommandLine.arguments[index + 1])
                let template = try NativeTemplate.read(templateURL)
                let raw = template.header + (try template.layout.encode(template.root))
                try raw.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
                print("Native serialization round-trip written locally.")
                exit(0)
            } catch { fputs("Round-trip failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--export-mpc"), CommandLine.arguments.count == index + 4 {
            do {
                let kit = try JSONDecoder().decode(Kit.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
                let folder = try NativeExport.export(kit: kit, templateURL: CommandLine.arguments[index + 2] == "builtin" ? nil : URL(fileURLWithPath: CommandLine.arguments[index + 2]),
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
            precondition(model.detailPath == short.path)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            precondition(model.playing == nil)
            model.preview(nil)
            precondition(model.detailPath == nil && model.detailName == nil)
            print("PASS: 20 rapid preview replacements (including 3-minute audio) in \(String(format: "%.3f", elapsed))s; newest selection wins; stop remains stopped")
            exit(0)
        }
        if CommandLine.arguments.contains("--self-test") {
            try! runFeatureChecks()
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
