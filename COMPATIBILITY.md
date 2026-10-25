# MPC Sample compatibility investigation

Observed in one user-supplied device project (not a general schema guarantee):

- XPJ is gzip-compressed, containing a text preamble then a JSON object.
- Preamble identifies `ACVS`, `1.3.0.12`, `SerialisableProjectData`, `json`, `Linux`.
- Top-level `data.version` is 28.
- Companion audio folder follows `<project>_[ProjectData]/`.
- Audio entries occur both at `data.samples` and in track sample lists.
- Drum layer assignments occur in
  `data.tracks[].program.drum.instruments[].layersv[]`, including `sampleName`
  and `sampleFile`. Instrument order appears to correspond to sequential pads.
- All 35 WAV files referenced by that project were found in its companion folder.
- There are 35 occupied instrument layers in the first drum track.

## Exporter behavior (0.2.4)

Native export reads a caller-supplied reference at runtime; it does not bundle
or distribute the user's project. Templates with unknown versions, multiple drum
tracks, or no empty-pad prototype are rejected. The template is never modified.

- Every instrument is cloned from the reference's empty-pad settings.
- Samples populate the first of eight layers; other layers remain unassigned.
- Original sample names populate layer and inventory names. Duplicate names receive
  pad suffixes to preserve distinct identities. Audio filenames use pad prefixes
  plus a sanitized/truncated original name; reports retain exact source names.
- Every output is a 24-bit PCM WAV with supported source rate and channel count.
- `sliceInfo.End` uses frame count minus one, as observed in untrimmed reference
  pads. The reference's zero sampleStart/sampleEnd sentinel fields are retained.
- Project-level and drum-track sample inventories are rebuilt.
- Sequence events/automation, song items, effects, and old sample references are
  cleared recursively. Existing routing and unknown device/controller defaults
  remain. This is not a fully documented manufacturer schema.
- Output is reread through gzip/JSON and checked for pad counts, layer counts,
  full sample end frames, old events and invalid/missing audio paths.
- Project names and companion directories use the kit name, sanitized for filesystems.
  Repeated exports receive numbered suffixes without overwriting existing output.
  Generated notes place the XPJ and companion directory directly under
  `MPC-Sample/Projects`, matching eight inspected device-saved projects.
  Failed output is removed.

## Observed load failure and serialization correction

A kit-named three-sample export was reported as "Error loading project" on the
MPC Sample. Read-only checks confirmed the card's XPJ and all audio files matched
the local export byte-for-byte and were placed beside each other under
`MPC-Sample/Projects`. This rules out an incomplete transfer for that attempt.

Earlier output used sorted JSON keys and rewrote integral floating-point tokens
(e.g. `1.0` to `1`). Version 0.2.4 keeps native object field order and unchanged
scalar token spellings through a template-aware writer. A no-change round trip
preserves all 608,123 tokens in the supplied reference (ignoring whitespace).
This is a compatibility hypothesis, not a proven explanation of the device error.
The [cereal archive documentation](https://uscilab.github.io/cereal/serialization_archives.html)
describes named and unnamed serialization; we do not have the MPC loader source.

No files were written to the card during diagnosis. No replacement export has
yet been confirmed to load on hardware.

## Validation evidence

Integration tests export 128 distinct generated WAV files across all eight banks,
and sparse assignments at A01, A16, B01, D16 and H16. They independently decode
the result, verify 24-bit sample payloads against known source values, frame
counts, channels and sample rates, verify empty layers/pads, rebuild a ZIP and
cross-check with the independent project inspector. Raw XPJ and ZIP templates
are exercised, as are invalid/missing inputs and failure cleanup. Source hashes
and the original reference archive remain unchanged.

## Remaining hardware validation

**No generated project has yet been loaded and saved successfully on an MPC
Sample.** Pad order is inferred from the reference, not confirmed on hardware.
A hardware load/save round trip must verify pad order across A–H, full sample
playback, levels/envelopes, routing, empty pads, and absence of inherited controller
state. A blank project saved by the same unit would improve the reference.

The guide documents 16 pads × 8 banks, supported audio rates and formats, and SD
Card Access. It does not define the serialized schema. Structural tests do not
establish hardware compatibility; app and reports clearly retain that distinction.
