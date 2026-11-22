# Danial MCP Editor: roadmap

The order of work. Design is in [architecture.md](architecture.md); IDs point
to [requirements.md](requirements.md).

Every phase ends with something that runs, with its MCP tools, its tests and
its performance checks. A phase is finished when its exit check passes.

## Phase 0: foundation and deciding tests

- Repository layout, Swift package, build and test scripts.
- Tests 1 to 4 from architecture section 15: many-cut 4K playback, joined
  export segments, HLG preview against export, pitch-kept speed.

Exit: the four results are written down and the playback and export paths are
chosen. Done: see [phase0.md](phase0.md).

## Phase 1: core and MCP

- `EditorCore`: data model, time maths, the timeline commands.
- `EditorKit`: command bus, journal, snapshot, crash recovery, undo, batches,
  settings.
- `MCPServer`: HTTP and stdio transports, generated tools, headless start
  (`dme`).
- Tools: app, project, history, batch, settings, media, timeline structure.

Exit: an agent builds and edits a 2,000-clip timeline with no window open,
the app is killed mid-edit and reopens with nothing lost, and the parity test
passes. Done: `scripts/e2e_recovery.py` checks all three against the real
server. Jobs and the event stream moved to phase 3, where the first
long-running work arrives.

## Phase 2: playback and manual editing

- Import by reference, composition builder, render graph with transform and
  alpha compositing, SDR and HDR output.
- Player and timeline views, transport, scrubbing.
- Keymap with the CapCut default: Space, jumps, Cmd+B, Q, W.
- Speed with pitch kept, audio tracks, gains, fades, join fades.
- Tools: clip properties, playback and review.

Exit: the playback targets in architecture section 16 hold on real footage,
and the owner can cut a raw recording by hand.

Measured in the app window: a 20-minute 1080p 30 test recording at speed
1.22 with 500 cuts played with 0 dropped frames at the start and in the
middle; a 4K 60 timeline with 500 cuts played 20 s with 0 dropped frames, the
app using 123 MB. Still open: the owner's own hand-cutting session. Moved on:
gain above 0 dB and waveforms to phase 3, keyframes to phase 5.

## Phase 3: analysis, transcription, automatic cuts

- Level envelopes, waveforms, loudness.
- Silence finder with the cut rules from settings.
- Edits bridge with busy detection, cleanup and quit (test 6).
- Transcripts stored in the project and mapped through cuts.
- Jobs (progress, wait, cancel) and the event stream.

Exit: an agent takes a raw recording to a tightened cut with a transcript,
and Edits is closed with no trace of the job.

Done. On a 20-minute test recording: 179 pauses found and cut in one step
(90 s), voice raised +3 dB by normalisation (peak-limited) and measured at
-19.7 LUFS afterwards. Transcription through Edits: 30 s of speech in 48 s,
62 words; Edits started and quit, its project deleted, its library and the
import folder left exactly as before. With a project open in Edits the job
waited and gave up without touching it. Open: "last take wins" (retakes)
needs the transcript and is left to the agent for now.

## Phase 4: colour

- Colour engine with the Adjust, White balance, HSL and Style groups, and
  picked colours in HSL.
- Looks, scoped assignment, saved profiles.
- Inspector controls, colour statistics and reference comparison tools.

Exit: a look made by hand and the same look set through MCP give identical
frames, and a saved profile reloads exactly.

Done. The inspector panel and agents call the same tools, so a look made
either way is the same data and the same frames; a look survives JSON (and so
a profile) exactly (tested). Every control is rendered on a test chart and
checked to do its job and nothing else (architecture section 6).

## Phase 5: effects

- Plug-in loader, manifest schema, generated inspector and MCP schema.
- First set: fade in, fade out, blur in, Gaussian blur.
- Transform keyframes for zoom.

Exit: a new effect is added by dropping a folder in place, with no change to
the app.

After phase 5: frames lost at cuts in open-GOP video fixed (lead-ins on
spare tracks, in-order capture and paused display; tested with a numbered
fixture, checked in the app: exact frames, 0 dropped frames).

Done. A plug-in folder dropped into the user folder loads, renders and shows
its generated controls; a broken one is reported with the reason (tested).
Every built-in effect is rendered on test charts and checked to do its job
and nothing else; keyframes stay on the picture through trims, splits and
speed changes (tested). A 4K frame with a blur takes 8.3 ms.

## Phase 6: export

- Segment renderer, encoder, joiner, audio pass, presets.
- Resume after interruption, re-render of changed segments only.
- Export panel in the UI, export verification tool.

Exit: exported frames match the player, an interrupted export resumes, and a
small edit re-renders only its segments.

Done. Every frame of an export of the numbered fixture is the right source
frame; an export stopped after two segments continues with those two; an
opacity change on one clip renders only the two segments it touches (all
tested). On real footage the export matches the editor's frame up to
encoding loss and runs at 5x real time for 1080p 30 and 1.6x for a 60 fps
HLG reel.

## Phase 7: HyperFrames

- Renderer comparison (test 5) and choice.
- Composition folders, slice cache, layer on the timeline, view-only block in
  the UI.
- HyperFrames tools.

Exit: an agent builds a composition, places it and fixes one part, and only
that part renders again.

Done. Renderer: the HyperFrames command line (test 5). Slices match a render
of the whole composition; fixing one sub-composition re-renders only the
slice that shows it (tested, and run through MCP in the app on
test footage: a 6 s composition rendered in 14 s, the fix in one slice).

After this phase the editor covers the whole current production flow.

## Phase 8: person matte

- Subject mask generated inside the editor, fed to the render graph.
- HyperFrames layers in front of and behind the subject.

Done. Masks from Apple Vision or imported SAM 3 masks, repaired in time,
stored as distances; depth compositions render in two passes and are cut
by the matte with the lit outline of the owner's style (tested in the
render graph, frame by frame on the timeline, and end to end with
HyperFrames; run through MCP in the app on test footage).
Clip effects run on both passes, and the elements cast a light shadow on
the wall behind the person (never on him).

## Phase 9: built-in browser

Optional extra, lowest priority.

- Web view with persistent profiles, sidebar and page layouts.
- Browser tools, results saved into the media pool.

Done. Results are saved as files in the project (`images/` or a
composition's `assets/`), since the media pool takes only video and sound.
Tested on a local generator page (typing, lists, uploads, drops, scripted
and real clicks, results at full quality, password refusal) and run in the
app after a sign-in: images generated on Google AI Studio with
Nano Banana Pro at 4K in every aspect ratio, site errors retried by
themselves.

## After the MVP: full test and additions

A full test of every phase on raw test footage (4K 60 vertical
HEVC, 1080p 30 landscape), through MCP and in the app window with a
self-test that works it with mouse and key events (`ui.selfTest`, 44
checks). Fixed on the way: export crashed in release builds (the app and
dme), the inspector's sliders never applied, panels were disabled without
a selection, clip.get showed timing only, whites did nothing on ordinary
footage, a 4K 1:1 picture from AI Studio counted as a failure, and a
shortcut right after an agent's seek used the old playhead.

Added: still pictures on the timeline (Nano Banana results go straight
into the media pool), the accent colour picker for motion graphics as a
native panel and tools, a live picture while a slider is dragged, CapCut's
copy, paste, duplicate, select all, marker, nudge and zoom keys, extract
audio, freeze frame, voice-over recording, and app tools for what the
owner sees (`ui.*`). Faster: exports favour speed in the hardware encoder
(1.6 times on 4K 60 HEVC), mattes run Vision at most 30 times a second
with a lighter motion fill (25 s of 4K 60 in 84 s instead of 117 s).

Open: voice-over and the first microphone question need the owner; the
Edits transcription step of that run; macOS privacy
grants are lost on each rebuild while the app is signed ad hoc.


Then the window got a way in to the tools a person editing by hand
needs (an audit found about 60 tools with none): Media, Clip and Words
panels, History and Settings windows (every setting and the keymap), Open
Recent, Project Settings, export verify, presets and cache, track header
buttons and menus, markers drawn in the ruler, a marked range, right-click
menus, dropping files, pictures in Import, transport buttons, keyframe
easing and menus that show the current keys. The self-test grew to 79
checks (84 with a download). Fixed on the way: a seek during a player rebuild was lost, and the
window missed edits made right after a project was created.

Then: sliders that fill from zero in two colours, more room in every
panel, menus laid out like a Mac app with a Keyboard Shortcuts list, Page
Up, Page Down and Return for clip edges, colour presets (save, update,
rename, delete, apply; the last one remembered), Agent Notes in the
window, a centred window, hour-long timelines and deeper zoom, and bar
waveforms. Fixed: a timeline ending in pictures stopped playback at the
last video; a seek right after an edit was cut to the old length.

## Reference downloads

Built: `social.download`, `social.info`, `social.inspect`, `social.list`
and `social.cleanup` over yt-dlp (D-1 to D-5), with the picture fallback
for photo posts and the `downloader` settings. Unit tests cover yt-dlp's
JSON, page tags, naming and sidecars, subtitle text, error kinds, the
command lookup and cleanup refusing media that clips use; a live test
(`DME_LIVE_SOCIAL=1`) downloads, inspects and trashes real public posts.

Exit: a YouTube video, a Pinterest video and image pin, and an X video,
sound and photo download, inspect and go to the Trash through the tools,
without a browser sign-in.

The window's Download from Link window is built and in the self-test (a
real YouTube video and Pinterest picture pin: download, look, place, keep
while used, trash). Open: posts that need a sign-in.

## Known issues, fixed after the MVP

All fixed: effects on depth compositions (with a light shadow of the
elements on the wall), a clip at 0 s on open-GOP video, fast fingertips in
Vision mattes, and timeline mouse work (clicks no longer move clips,
snapping, trims stop at neighbours, Cmd+B cuts the selected clips' tracks
at the playhead as shown).

