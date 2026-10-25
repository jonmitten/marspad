# MarsPad

A local macOS sample librarian and pad-bank planner for Akai MPC Sample owners.
MIT licensed. Unaffiliated with Akai Professional or Samples from Mars.

## Current release: 0.2.1 prototype

- Scan extracted audio collections without modifying source files. ZIPs are skipped.
- Search by filename or folder, filter collections and inferred sound categories.
- Audition audio using asynchronous macOS playback; selecting a sound immediately
  detaches the previous preview without waiting for a full-file decode. Format
  support depends on macOS.
- Assign samples to 16 pads across banks A–H by dragging or using Assign Selected Sound.
- Auto-fill empty pads in the current bank using the current library filters.
- Save/open editable `.marspad` kit plans. These reference original absolute paths.
- Export unchanged sample copies and a CSV pad map into a fresh output folder.

- Export a native `.xpj` plus companion audio directory using a device-saved template.

Native export has passed structural and audio checks. **Hardware validation is
pending**: verify a separate small project on your device before relying on it.
Audio-only export remains available for manual assignment. The app writes new
folders, never firmware or device system files.

## Export to MPC Sample

1. Save your kit plan, then choose **Export MPC…**.
2. On first export, select a project saved by your MPC Sample: an `.xpj` or a ZIP
   containing one. A template with at least one empty pad is required. This
   release accepts only AC50 / engine Sample / schema 28 / preamble 1.3.0.12.
   The supplied template stays unchanged and is not bundled in the source code.
3. Choose a local destination. The app writes a fresh `MarsPad-<id>` folder with
   `MarsPad-<id>.xpj`, `MarsPad-<id>_[ProjectData]/`, an assignment report, and notes.
4. Copy that whole folder to a separate location on your microSD card. Keep the
   `.xpj` beside its matching audio folder. Safely eject the card before leaving
   SD Card Access mode.
5. Save your current MPC project, load the exported `.xpj` via the Project menu,
   and verify bank boundaries, full sample playback, and empty pads. This is the
   remaining hardware validation step; software checks cannot establish it.

The template path is remembered. Right-click Export MPC… and choose Change MPC
Template… to select another reference. Export snapshots the kit so subsequent
edits do not change an in-progress export.

Audio is streamed into 24-bit PCM WAVs, retaining source rate and channels.
Mono/stereo at 44.1, 48, or 96 kHz and up to 20 minutes per sample are supported;
other rates/channels or unreadable files fail with the affected pad identified.
Sources are not normalized or changed. Export uses the template's empty-pad
settings for every instrument, sets each sample's full inclusive end frame,
clears old sample references, sequence events, song items and effects, and retains
routing and other unknown schema defaults. It creates a clean kit, not a copy of
the template's music. Other retained device/controller defaults still need a
hardware check. Partial exports are removed on failure.

## Build and run

Requires macOS 13+ and Apple Command Line Tools / Xcode with Swift 5.9+.

```sh
./build-app.sh
open "dist/MarsPad $(cat VERSION).app"
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
`python3 tools/test_native_export.py /path/to/MarsPad /path/to/reference.zip`
checks native exports using generated audio and your read-only reference.
It covers all banks, sparse assignments, PCM payloads, sample lengths, missing
files, invalid templates, unsupported rates, and cleanup. No proprietary fixture
is committed. See COMPATIBILITY.md for evidence and limits.

## Repository boundaries

Commit code and documentation only. Do not commit commercial audio, personal
MPC projects, exported kits, local library indexes or absolute personal paths.
No audio or supplied project is bundled with this repository. MIT applies to this
application's code; it does not relicense any imported sample content.

## Audio details and build identity

Select a library sound or populated pad to see duration, bit rate, PCM bit depth,
sample rate and channel count beneath the library. **Show in Finder** reveals that
file, including when metadata or preview fails. Its path is displayed and can be
copied. Stopping playback keeps the inspected file available. Metadata failures
show the underlying error; metadata and playback use separate readers, so a
metadata failure alone does not establish that the audio cannot play or export. Header reads happen in the
background; stale selections cannot overwrite the current details. Compressed
durations are marked approximate, and unavailable properties are labeled. Bit
rate is audio data per second (kb/s); bit depth is shown separately for PCM.

The footer shows the version from VERSION and the Git commit embedded when
packaged. Builds from modified source have a `-dirty` suffix. Direct `swift run`
launches show development/unpackaged rather than claiming a release identity.
An existing binary can be packaged with `./build-app.sh /absolute/path/to/MarsPad`;
use a binary built from the current checkout so the embedded identity is accurate.
