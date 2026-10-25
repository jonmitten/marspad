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

The inspected file includes existing sequences, effects, trim settings and other
parameters. Copying its full program as a kit template could inadvertently inherit
those settings. Native export requires neutral parameter semantics, sample length
and trim rules, empty-pad behavior, bank numbering and project round-trip checks.
A minimal blank device project and hardware load/save verification would strengthen
that evidence. No native export is enabled until those questions are resolved.

The guide documents 16 pads × 8 banks, supported import formats/rates, and the
`MPC-Sample/Samples` default directory. It does not document the serialized schema.
The app currently exports unchanged audio and a human-readable map only. No claim
of native project compatibility or hardware validation is made.
