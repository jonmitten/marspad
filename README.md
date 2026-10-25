# MarsPad

A local macOS sample librarian and pad-bank planner for Akai MPC Sample owners.
MIT licensed. Unaffiliated with Akai Professional or Samples from Mars.

## Current release: 0.1.3 prototype

- Scan extracted audio collections without modifying source files. ZIPs are skipped.
- Search by filename or folder, filter collections and inferred sound categories.
- Audition audio using asynchronous macOS playback; selecting a sound immediately
  detaches the previous preview without waiting for a full-file decode. Format
  support depends on macOS.
- Assign samples to 16 pads across banks A–H by dragging or using Assign Selected Sound.
- Auto-fill empty pads in the current bank using the current library filters.
- Save/open editable `.marspad` kit plans. These reference original absolute paths.
- Export unchanged sample copies and a CSV pad map into a fresh output folder.

**Native MPC Sample project export is not implemented or hardware validated.**
Audio exports do not automatically load pad assignments on the MPC. They are for
manual import. The app never writes to firmware or device system files.
It does not convert audio: verify import compatibility before transfer.

## Build and run

Requires macOS 13+ and Apple Command Line Tools / Xcode with Swift 5.9+.

```sh
./build-app.sh
open dist/MarsPad.app
```

The build is locally ad-hoc signed; public distribution would require release
packaging, signing and notarization. Run `swift test` for model checks.
If XCTest is unavailable in Command Line Tools, run `swift run MarsPad --self-test`
for the built-in model checks. `swift run MarsPad --preview-self-test` exercises
rapid switching with generated silent audio, including a three-minute file.
Only the development Mac architecture is built by default. Windows/Linux are
future work; the SwiftUI interface would need replacement or a separate frontend.

Choose Library and select your extracted Samples from Mars folder. Select a sound
to preview it, select a pad, then Assign Selected Sound, or drag it onto a pad.
Auto-fill first places preferred categories, then fills remaining empty pads with other
unused sounds matching the current filters. It keeps occupied pads and avoids
reusing files assigned anywhere in the kit. If too few eligible sounds remain,
the status explains why some pads are empty. Category
inference is based on folder/name tokens; ambiguous names appear under Other.
Clear a pad using its context menu. Clear Bank A–H removes every assignment in
the selected bank while keeping the other banks unchanged. Save Kit before quitting; there is no autosave.
Saved kits are machine-local plans; moving sample folders breaks their references.

## Native format investigation

`python3 tools/inspect_project.py /path/to/project.zip` performs a read-only archive
integrity and sample-reference check, printing inferred assignments. It does not
extract files, execute project content, or generate device projects.
See COMPATIBILITY.md for observations and remaining work.

## Repository boundaries

Commit code and documentation only. Do not commit commercial audio, personal
MPC projects, exported kits, local library indexes or absolute personal paths.
No audio or supplied project is bundled with this repository. MIT applies to this
application's code; it does not relicense any imported sample content.
