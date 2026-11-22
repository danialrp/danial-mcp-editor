# Danial MCP Editor: architecture

How the editor is built. What it must do is in
[requirements.md](requirements.md); IDs such as `N-1` point there. The tool
list is in [mcp-tools.md](mcp-tools.md) and the build order in
[roadmap.md](roadmap.md).

Status: design, before any code. Section 15 lists the technical tests that
must pass before the parts that depend on them are built.

## 1. Shape of the system

One native app, one process. Everything goes through one command layer.

```
   MCP clients (agents)        Owner
          │                      │
   ┌──────▼──────┐        ┌──────▼──────┐
   │  MCP server │        │  UI (AppKit │
   │  (local)    │        │  + SwiftUI) │
   └──────┬──────┘        └──────┬──────┘
          └──────────┬───────────┘
              ┌──────▼──────┐
              │ Command bus │  one actor, one order of events
              └──────┬──────┘
              ┌──────▼──────┐      ┌───────────────┐
              │ Project     │─────▶│ Journal +     │
              │ store       │      │ snapshot      │
              └──────┬──────┘      └───────────────┘
                     │ state changes
   ┌─────────┬───────┼─────────┬───────────┬──────────┐
   ▼         ▼       ▼         ▼           ▼          ▼
 Playback  Export  Analysis  HyperFrames  Edits     Browser
 engine    engine            host         bridge    host
   └────┬────┘
        ▼
  Render graph (Metal) + audio graph
```

Rules that hold everywhere:

1. The UI and the MCP server are both clients of the command bus. Neither has
   a private path to the model (M-1, S-1).
2. Commands address things by ID. No command depends on what is selected or
   which panel is open, so an agent and the owner can work at the same time.
3. The same render graph produces preview frames and export frames, so what
   plays is what is exported (P-1, N-6).
4. Source media is never copied or transcoded on import. The app reads the
   original files (N-1, P-2).

## 2. Modules

Swift packages inside one repository. Lower rows never import higher rows.

| Package | Contents | Depends on |
|---|---|---|
| `EditorApp` | Windows, timeline view, player view, inspector, keymap handling | all below |
| `dme` | The editor without a window: starts the MCP server over HTTP or stdio | `MCPServer`, `MediaEngine` |
| `MCPServer` | JSON-RPC handler, HTTP and stdio transports, tool schemas from the catalog | `EditorKit` |
| `BrowserHost` | Web view, profiles, automation commands | `EditorKit` |
| `HyperFramesHost` | Composition folders, slice renderer, slice cache | `EditorKit`, `MediaEngine` |
| `EditsBridge` | Client for the Edits app, lifecycle and cleanup | `EditorKit` |
| `Social` | Reference downloads through yt-dlp, page tag fallback, inspection, cleanup | `EditorKit`, `MediaEngine` |
| `ExportEngine` | Segment renderer, encoder, muxer, presets | `MediaEngine` |
| `PlaybackEngine` | Composition builder, player, frame capture | `MediaEngine` |
| `Analysis` | Audio levels, silence finder, loudness, frame statistics | `MediaEngine` |
| `MediaEngine` | Decoding, render graph, colour engine, effects, audio graph | `EditorCore` |
| `EditorKit` | Command bus, project store, journal, undo, user settings, tool catalog, jobs | `EditorCore` |
| `EditorCore` | Data model, commands, time maths. Pure Swift, no Apple media frameworks | none |

`EditorCore` has no dependency on AVFoundation or Metal. It is tested without
media and is the only place where editing logic lives.

The app can start without a window (`--headless`), so an agent can run a whole
job with no UI on screen (N-2).

## 3. Data model

All types are value types and `Codable`.

- **Time.** Rational, in ticks of 1/240000 s. That base divides evenly by 30
  and 60 fps frames and by 48 kHz audio samples, so cuts land on exact frames
  and exact samples (A-4).
- **Project.** Canvas size, frame rate, dynamic range (SDR Rec.709 or HDR
  Rec.2100 HLG), tracks, media pool, looks, transcripts, markers.
- **Media asset.** A reference to a file (path plus bookmark and a content
  fingerprint), with probed properties: codec, size, frame rate, colour tags,
  audio layout.
- **Track.** Kinds: `main` (the camera footage, ripple behaviour), `overlay`
  (layers above it), `audio` (voice, music, sound effects).
- **Clip.** Asset, source range, timeline start, speed, transform keyframes,
  opacity, effect instances, look reference, audio gain, fades.
- **HyperFrames layer.** A composition folder and the timeline range it
  covers. Renders into slice clips (section 9).
- **Look.** A set of colour parameters (section 6), stored once and referenced
  by clips or by a whole track (C-2, C-3).
- **Transcript.** Words with source-time ranges, tied to an asset. Timeline
  positions are derived through the clip mapping, so a transcript follows
  cuts and speed changes without being rewritten (T-4).

A project is a folder package:

```
Name.dmeproj/
  project.json        last compacted snapshot
  journal.jsonl       commands applied since that snapshot
  hyperframes/        composition folders
  looks/              looks saved in this project
  notes/              markdown notes for agents and the owner (M-7)
  cache -> (outside the package, in the user cache folder)
```

Notes are plain markdown files with a short header (title, clips, time
range, the project revision when written, time of writing). They sit outside
the command journal and undo: they describe the edit rather than being part
of it. Writes are atomic file replacements; a removed note goes to the Trash.
`agent.onboard` reads the index, `spec.md` and `progress.md`, and compares
the newest note revision with the project to list the commands applied since.

Media stays where it is. Caches live outside the package and can be deleted at
any time without losing work.

## 4. Commands

A command is a small `Codable` value whose stored properties are exactly its
tool arguments:

```swift
protocol EditorCommand: Codable, Sendable {
    static var name: String { get }          // "timeline.split"
    static var spec: CommandSpec { get }     // description and parameters
    mutating func prepare(in project: Project) throws
    func apply(to project: inout Project) throws
}
```

- `prepare` runs once, before the first apply: it snaps times to the frame
  grid and assigns the ids of anything the command creates. The journal
  stores the prepared command, so replaying it after a crash gives exactly the
  same result, ids included.
- The command bus (`EditorSession`) is one actor. It prepares and applies the
  commands on a copy of the project, writes the journal line, then makes the
  copy current.
- **Undo and redo** keep the project as it was before and after each step.
  Projects are value types, so unchanged tracks and clips share storage and a
  step costs only what it changed. Every command is undoable with no extra
  code (M-2). The undo depth is a user setting.
- **Batches.** A list of commands can be applied as one atomic step with one
  undo entry and one notification. Editing hundreds of clips is one call.
- **Revisions.** Every applied command increments the project revision.
  A caller may pass the revision it last saw; a mismatch fails the call
  instead of editing stale state.
- **Registry.** Each command registers its name, parameter schema and
  description once. MCP tools, menu items and keymap actions are generated
  from the registry, which is how parity is kept (N-2).
- **Queries** are the read side: pure functions over the project or over an
  engine, registered the same way (M-3).
- **Jobs.** Work that takes time (export, analysis, transcription,
  HyperFrames render, image generation) runs as a job with an ID, progress,
  result and cancel. Jobs never block the command bus.

### Autosave and recovery

The journal line is written and flushed before a command is reported as done.
After a crash the app loads `project.json` and replays the journal (N-4, L-1,
L-2). The snapshot is rewritten atomically when the journal grows past a set
size and when the project closes. There is no save button.

## 5. Playback and rendering

### Decoding

VideoToolbox hardware decoding of the original files through AVFoundation.
No proxy files are generated. A clip that cannot be decoded in real time is
reported to the caller, and nothing is transcoded silently.

The compositor offers the decoders a list of pixel formats and each decoder
hands over one it produces natively: 10-bit HEVC arrives as `x420`, 8-bit as
`420v`, and video with alpha (ProRes 4444, HEVC with alpha) as `y416`. The
alpha format must come first in the list: an HEVC file with alpha can also
produce `x420` natively, which silently drops its alpha (measured in phase 2).
A decoded frame that cannot be read is skipped and the frame below shows.

### Timeline to composition

The project is translated into an `AVMutableComposition`: one segment per
clip, speed applied by scaling the segment's time range, audio pitch kept with
the spectral time-pitch algorithm (E-6). Rebuilding the composition after an
edit touches only segment tables, so it stays cheap with hundreds of cuts.
`AVPlayer` drives playback and owns the audio and video clock, which keeps
sync after any number of cuts (A-4).

The playback engine sits behind a protocol. If measurements in section 15 show
that this path cannot hold the targets, a custom engine (own decode scheduling,
Metal presentation, audio-driven clock) replaces it without touching the rest.

### Render graph

A custom video compositor renders every frame with Metal:

```
for each visible layer, bottom to top:
  decoded pixel buffer (zero-copy texture, 8 or 10 bit YUV)
    → to linear working space (Rec.2020 primaries, 16-bit float)
    → look, only if the clip or its track has one        (section 6)
    → effects in order                                    (section 7)
    → transform: position, scale, rotation from keyframes
    → composite with premultiplied alpha
→ to output space: Rec.709 SDR or Rec.2100 HLG
→ screen (HDR, or an SDR preview converted last) or encoder
```

- Looks and effects are per clip, so graphics layers pass through untouched
  (C-3).
- An SDR source in an HDR project is placed at reference white and is not
  stretched: BT.2408, SDR white at 203 cd/m², with the HLG system gamma
  (1.2) undone on luminance, so it looks on an HLG display as it does in SDR
  (a test checks this against the BT.2100 reference display).
- The shader is the only SDR/HLG converter. A layer's colour space comes
  from its file's format description, and the composition's tracks are
  retagged with the composition's transfer and primaries (not the matrix),
  because AVFoundation's own conversion skips the first frame of every
  decode session and tags converted and unconverted frames alike. The
  retag also drops the Dolby Vision box of HLG files, which triggers tone
  mapping by itself. Spaces
  the shader does not convert (PQ, Display P3) are left to AVFoundation.
  Colour tests go through encoded files and a built composition and check
  every frame, not the first.
- Preview range (setting `preview.dynamicRange`: `auto`, `project`, `sdr`).
  Raw footage must look as the same file does in a plain player or in the
  editor chosen with `preview.gamma` (below). SDR footage sent to the screen as HLG does not: it is brighter or
  darker with the display's headroom and with the window in front or behind
  (measured). So `auto` plays an HLG project in HLG only when its timeline
  has HDR footage and the display has HDR (potential headroom, watched as
  the window moves); otherwise in SDR. The SDR preview is the HLG frame,
  with looks, effects and blending as exported, converted last: exact up to
  white for SDR material, rolled off as in an SDR project with HLG material.
  One opaque SDR picture with no effect or depth skips HLG: the result is the
  same, and pure colours stay pure (through half-float HLG and back their
  empty channels rose by up to 12 levels).
  Only the player and what is drawn over it use it. Export, `frame.capture`
  and the colour tools keep the project's range.
- Preview gamma (setting `preview.gamma`). Editors disagree on how an SDR
  file looks, so one preview cannot match them all (measured on screen,
  same file and display):
  - `video` (default): gamma 1.961, the CoreMedia Rec.709 colour space, as
    CapCut and plain players show it (grey 8 as 4 to 7, 128 as 139).
  - `edits`: the BT.709 camera curve, as Edits shows an SDR project (8 as
    20, 128 as 141). Edits in an HDR project is not a reference for SDR
    footage: it stretches white to the display's headroom (measured).
  The colour space is always attached to SDR frames: from the tags alone
  the player reads the camera curve and the image generators 1.961. The
  camera curve is built from the precise constants; with the rounded ones
  macOS substitutes `itur_709`, which is gamma 2.4. The setting reaches the
  player and the stills over it, nothing else.
- Caches tell open projects apart by the session's `instanceID`, never by
  the object's address, which the next session can reuse, and keep the
  preview modes (range and gamma) apart. An HDR source in an SDR project is tone mapped.
- HEVC and ProRes 4444 with alpha are decoded with their alpha channel and
  composited directly.
- When paused, a parameter change re-renders only the current frame.
- A time with no source picture (a gap, or a file whose first frame starts
  after zero) renders black. Returning an error there stops playback for the
  whole timeline (found in phase 0).

### Open-GOP video

Cameras and screen recorders often write open-GOP HEVC: the 2 or 3 frames
shown just before a keyframe are decoded after it and refer to the group
before. AVFoundation starts decoding at that keyframe when a segment begins
on such a frame, so those frames never come out (found on a test recording: 2 to 3 frames lost at about one cut in ten). Measured behaviour
and the design that follows from it:

- `DecodeStart` reads the file's sample table (decode and display order,
  keyframe flags) and tells, for a clip's first frame, whether it is such a
  leading frame and which earlier keyframe decoding must start from.
- Such a clip goes on a spare composition track, inserted from the earlier
  keyframe. The extra frames before the clip (the lead-in) are decoded but
  not drawn: the instruction lists the spare track as needed during the
  lead-in, and the compositor skips it. The lead-in plays at the clip's
  speed when there is room before the clip and is squeezed into the room
  there is otherwise (measured to work down to 4 ms). Spare tracks are reused
  when free. Playing and exporting straight through then give every frame.
- Jumping straight to one of those frames still fails, in a way that depends
  on the reader: an image generator returns another frame of the file, and a
  reader whose time range starts on one waits forever. The built composition
  lists these short stretches (`inOrderOnly`). Frame capture decodes them in
  order from the lead-in; `safeStart` moves any read start out of a stretch;
  the player seeks to the lead-in and steps forward, and while paused there
  the window shows the frame from frame capture over the player (an sRGB
  picture, so its brightness can differ slightly from the video). Export
  segments (phase 6) must start through `safeStart` too.
- A clip at exactly 0 s has no room for a lead-in. The builder then also
  builds the same timeline one second later, where it has, and keeps it
  with the composition (`preroll`). Export renders the picture from that
  one, frame capture and the paused player read those first frames from
  it, and the sound comes from the timeline as it is. Plain playback from
  0 s can still show other frames for those first few frames.

### Memory and disk

- Textures come from a fixed-size pool. Decoded frames are not retained past
  presentation.
- Timeline thumbnails and waveforms are generated lazily and stored in a
  bounded cache with least-recently-used eviction.
- The only rendered media the editor writes are HyperFrames slices and export
  segments, both in the bounded cache.

## 6. Colour engine

A look holds the parameters named in C-1:

| Group | Parameters |
|---|---|
| Adjust | exposure, clarity, highlights, shadows, contrast, brightness, whites, blacks, saturation, vibrance |
| White balance | temperature, tint |
| HSL | hue, saturation, luminance for eight fixed bands and for any number of picked colours |
| Style | sharpen, noise reduction, fade, vignette, grain |

- The look runs in the layer shader, in the same pass that decodes the
  picture, before it is converted to the project's colour space, so preview,
  frame capture and export give the same result. A layer without a look
  skips all of it.
- Order: noise reduction and sharpen (from the luma of the four
  neighbouring pixels), clarity (two rings of samples at 0.8% of the
  picture's longer side and half of it, so preview and a 4K export look the
  same), exposure (in linear light, ±1.5 stops at ±100, with a shoulder that
  rolls bright colours toward white with their hue instead of clipping one
  channel), white balance, then one tone curve on luma (highlights, shadows,
  whites, blacks, brightness, contrast as an S-curve about 50%), saturation
  and vibrance, HSL bands and picked colours (hue shift up to ±30°,
  saturation and value scaled), fade, vignette, grain (new every frame). The
  formulas are in `Sources/MediaEngine/Render/Shaders.swift`.
- The tone controls change light, not colour: the curve gives each pixel a
  new luma and its channels are scaled together, so hue and colourfulness
  stay (next to black the change is added as grey, so noise is not
  multiplied; a colour pushed past white moves toward grey of the same luma
  until it fits). Each part of the curve is monotone on its own range and
  they are applied one after another, so no combination of sliders can swap
  two tones.
- Adjust and white balance sliders, fade and vignette answer softly near 0
  (half the slope at 0, one and a half at 100). One step of any slider moves
  no pixel by more than 4 levels of 255, and four steps from 0 by no more
  than 5: a few steps are a fine touch, never a different picture.
- The scale is this editor's own: values are not meant to equal Edits' or
  CapCut's. What is fixed is behaviour. Each control is rendered through the
  shader on a test chart (grey steps, the eight band colours strong and weak,
  skin, fine and coarse detail, flat grey) and must do its job and leave the
  rest alone: highlights leave tones below 40% untouched, shadows those
  above 50%, whites below 55%, blacks above 30%; brightness and contrast keep
  black, white and the order of tones; saturation and vibrance keep greys and
  brightness; temperature leaves green and tint moves red and blue together;
  sharpen, noise reduction and clarity leave flat areas untouched; a zero or
  disabled look changes nothing (`Tests/MediaEngineTests/LookRenderTests.swift`).
  Every slider is also swept one step at a time over its whole range on a
  256-tone ramp and colour rows, checking the step limits, tone order, hue,
  direction and a visible effect at the ends, alone and in pairs at their
  ends (`LookSweepTests.swift`). `LookSheetTests.swift` writes a contact
  sheet from any frame for judging by eye.
- Slider values reach the compositor through a look table kept with the
  built composition and read at every frame. A change that only moves look
  values (a drag, or `look.update`) updates that table: no composition is
  built, playback picks the values up at the next frame and a paused frame
  is drawn again. A colour slider follows the mouse through ordinary events
  rather than NSSlider's tracking loop, in which the player would not draw;
  a double click puts it back to 0.
- Saturation and vibrance stop at the edge of the colour range, so a boost
  never clips a channel and changes brightness.
- An HSL band reaches from its own hue to the hues of the bands on either
  side, falling to zero there. All weights add up to one, so changing a band
  touches its own colour and the hues between it and its neighbours, never a
  neighbour's own colour.
- Evaluated per pixel rather than baked into a lookup table: simpler, and
  fast enough for 4K playback. A table can come later if a
  measurement needs it.
- A picked colour (C-1a) is a hue with a reach in degrees and a soft edge,
  weighted by how close a pixel's saturation is to it. At most four per look.
  The colour comes from `color.sample` or the system colour sampler.
- A look is a small JSON file. Saving a profile writes it to `looks/` next to
  the settings file; loading one copies it into the project as a new look
  (C-2).
- Scope: a look is attached to a clip, to a list of clips or to a track.
- For agents: frame capture, histogram and waveform statistics, per-region
  averages, and a comparison of a timeline frame against a reference image
  (C-5). The agent reads the numbers, sets parameters, and reads again.

## 7. Effects

An effect is a plug-in folder with a manifest and Metal source:

```
Effects/blur.gaussian/        built in (in the app: Contents/Resources/Effects)
  manifest.json               id, name, kind, passes, parameters, duration, mipmaps
  effect.metal                fragment functions written with EFFECT(name)
<settings folder>/effects/    the owner's own plug-ins, same layout
```

- A plug-in is shader source and data only, no executable code. It is
  compiled at load with a fixed header (`effectShaderHeader` in
  `EffectCatalog.swift`) that gives it the `EFFECT(name)` signature, the
  context (picture size, pixel size, progress, time in the clip, a size scale
  of short side / 1080, a per-frame seed, the pass index), the parameters as
  floats in manifest order, and helpers (`fxEase`, `fxGaussian`).
- The manifest's parameter list (number with range, boolean, choice) is
  checked by the effect tools and generates the MCP schema text and the
  inspector controls, so a new effect needs no change to the core, the UI or
  the MCP layer (X-2). A folder dropped into the user folder appears after
  `effect.reload` or the next start; a broken one is listed with the reason
  (compile error, missing function, bad manifest) and never stops the others.
  A user plug-in with a built-in's id replaces it.
- Kinds: `filter` (whole clip), `in` (progress 0 to 1 over its duration from
  the clip start) and `out` (progress 0 to 1 ending at the clip end). On a
  split the left half keeps the `in` effects and the right half the `out`
  effects; filters go on both. Sound fades follow the same rule: the
  fade-in stays on the left half and the fade-out on the right, so a cut
  never dips the sound; a trim, cut or speed change that makes a clip
  shorter than its two fades shrinks them in proportion.
- An instance stores the plug-in id, its kind and all parameter values in
  the clip, so a changed plug-in default does not change old projects. A
  missing plug-in is skipped at render and shown in the panel.
- Render path: a clip without effects is drawn straight onto the frame, as
  before. A clip with effects is first drawn with its look at its own size
  into an offscreen half-float texture, each pass then runs into a second
  texture (ping-pong), and the result is placed with the clip's transform.
  All of it is one GPU command buffer per frame; textures come from a pool,
  so playback allocates nothing. Effects run in the output colour space with
  premultiplied alpha.
- `"mipmaps": true` makes the GPU build mipmaps of each pass input. The
  Gaussian helper then reads a coarser level for wide radii, so it takes at
  most 6 taps each side at any radius without aliasing.
- Measured, one 4K frame (`EffectPerformanceTests`): plain
  1.8 ms, with one simple effect 2.4 ms, with a Gaussian blur 8.3 ms at any
  radius (19 ms before mipmaps). A blur at a lower working resolution would
  cut this further; it is not built because the measured cost fits the frame
  budget (N-1a).
- First set (X-1, E-8): `fade.in`, `fade.out`, `blur.in`, `blur.gaussian`.
- The person matte (X-3) will arrive as texture 1 of every effect pass; until
  then it is one white pixel and `hasMatte` is 0.

### Keyframes (E-7)

- A clip can animate x, y, scale, rotation and opacity. Each keyframe has a
  time, a value and an easing toward the next one (linear, ease, hold).
- Times are stored in the clip's source time, so a keyframe stays on the
  same picture through trims, splits and speed changes. Tools take timeline
  time by default and convert it once, in `prepare`.
- The compositor evaluates keyframes and effect progress per frame. Clips
  with neither take the static path.

## 8. Audio

- Internal format: 48 kHz, 32-bit float.
- Timeline audio is part of the same composition as the picture. Gains, fades
  and the short join fade at every cut (E-9) are volume ramps in the audio mix,
  with pitch kept on speed changes (spectral time-pitch).
- The audio mix can only lower a level. For gains above 0 dB a track's
  volume ramps are scaled by its largest gain and an audio tap multiplies the
  track by that gain again, so each clip ends at exactly its own gain.
- Sound effects and music are ordinary clips on audio tracks (A-1, A-2, A-3).
- Loudness is measured to ITU-R BS.1770 (integrated, short-term, true peak)
  and offered as a query, so an agent can set gains against a target.
- Export: AAC at the highest bitrate the preset allows, or uncompressed PCM in
  a MOV container when the preset asks for it (F-5).

## 9. Analysis

- **Levels.** RMS and peak per 10 ms for each media file, read as a stream
  (a 20-minute file is never held in memory), computed once and cached on disk
  by the file's fingerprint. They feed the timeline waveforms and the silence
  finder (A-5).
- **Loudness.** Integrated loudness to ITU-R BS.1770 (K-weighting, 400 ms
  blocks, absolute and relative gates), loudest 3 s and highest sample peak,
  of a file or of the timeline as it sounds.
- **Silence finder.** The production flow's rules, deterministic (E-10):
  loud speech is the 99.5th percentile of levels; silence is 20 dB below it;
  a sound of 60 ms or less between silences is a click; the quiet end of a
  word (down to 15 dB under the silence line) belongs to the word; padding is
  kept after the word and before the next one; the silence after the last
  word is never cut, and neither is a pause at a clip's own edge. Cut edges
  are rounded inward to whole frames, so they never touch sound.
  `audio.findSilence` only lists the cuts; `audio.applySilenceCuts` makes
  them in one undoable step and sets the join fades.
- **Voice level.** `audio.normalize` measures the track alone and sets one
  gain on its clips to reach the loudness target, stopping earlier if the peak
  would pass the ceiling, in 0.5 dB steps.
- **Frame statistics** for the colour tools (section 6).

Default cut rules, taken from the current Edits flow and stored in settings:

| Setting | Default |
|---|---|
| Speed for talking-head footage | 1.22 |
| Loud speech | 99.5th percentile of 10 ms levels |
| Shortest pause that is cut | 0.25 s |
| Silence threshold | 20 dB below loud speech |
| Quiet word ending | down to 15 dB below the silence line |
| Click (counts as silence) | 60 ms or shorter |
| Kept after the last word | 0.35 s |
| Kept before the next word | 0.10 s |
| Join fade | 0.05 s |
| Voice loudness target | -16 LUFS, peak ceiling -1 dB |

## 10. Transcription bridge

A client for the Edits app's local MCP server (T-2).

```
job ─▶ extract the sound to a temporary WAV in ~/Movies (Edits imports only there)
          ▼
   Edits running? ──yes──▶ in use? ──yes──▶ wait, touch nothing; give up after a limit (T-3)
          │ no                 │ no
          ▼                    ▼
   start it in the background  use it as it is
          ▼
   new project named after the job ─▶ import the WAV ─▶ transcribe
          ▼
   close and delete that project, Trash the WAV and Edits' copy of it
          ▼
   quit Edits if the job started it                              (T-3a)
          ▼
   store the words in our project
```

- "In use" means Edits was already running and has a project open or an
  export running. When the job starts Edits itself, a project Edits reopens
  on its own does not count: nobody is using it.
- Edits that was already running and idle is used and left running, because
  someone else started it.
- Edits copies an imported file into its library under a random name; the
  bridge finds that copy by the job's WAV size and Trashes it. Other new
  library files (for example proxies of a project Edits reopened) are only
  reported, never removed.
- A lock file serialises bridge jobs from several editor instances.
- Cleanup runs even when the job fails. If something cannot be removed, the
  job result lists it.
- The connection details of the Edits server are read from local settings and
  never stored in a project or in the repository.
- The bridge sits behind a `Transcriber` protocol, so another source can be
  added later without changes elsewhere (T-5).

## 11. HyperFrames host

- A composition is a HyperFrames project folder inside the project package
  (`hyperframes/<id>/`: `index.html`, `compositions/`, `assets/`). It is a
  media asset of kind `hyperframes`, so it is placed, moved, trimmed and
  split like any clip. Agents edit its files through the `hf.*` tools or on
  disk.
- Rendering is done by the HyperFrames command line (headless Chrome),
  chosen by test 5 ([phase0.md](phase0.md)). The command is a user setting
  (`hyperframes.command`), so a machine can point it at its own wrapper that
  pins a version.
- A composition renders in slices of `hyperframes.sliceSeconds` (default 5)
  with alpha. HyperFrames renders alpha output only from time 0, so each
  slice renders from a copy of the folder shifted to the slice (`HFDocument`):
  elements with `data-start` are moved or trimmed to it, sub-compositions
  get their own offset, and every registered GSAP timeline is wrapped so the
  copy's time 0 plays the slice's start. Every slice frame matches a render
  of the whole composition (tested).
- A slice is cached under a hash of what its frames depend on: the root
  page, the sub-compositions it shows during the slice, every other file of
  the folder (large files by size and date), the HyperFrames version and the
  render settings. A change to one sub-composition re-renders only the
  slices that show it (H-4, tested). HyperFrames writes ProRes 4444; the
  slice is kept as HEVC with alpha, which is small and plays in hardware.
- Up to `hyperframes.parallelSlices` slices render at once.
- The timeline plays each slice's current render, or its last render while
  it is stale; a slice never rendered is empty. When renders finish, the
  player rebuilds.
- Looks never apply to a composition (C-3). Export renders missing slices
  first; their hashes are part of the export segment hashes.
- In the window the layer is an amber block marked view-only: it can be
  selected but not dragged or trimmed by hand (H-3).
- A depth composition (elements `#back` and `#front`, hidden per pass by
  the classes `pass-back` / `pass-front` on `<html>`) renders each slice in
  two passes, stacked in one file: back on top, front below. Its
  `const EDGE = [[start, end], ...]` lists when the person's outline is lit.
  `<video id="src">` (footage placed only for previewing in Studio) is left
  out of every render.

### Person matte (X-3)

- A footage file's matte (`MediaAsset.matte`: `vision` or `imported`,
  command `media.setMatte`) follows source time. `MatteStore` makes it in
  chunks of `matte.chunkSeconds` source seconds, cached in
  `~/Library/Caches/DanialMCPEditor/mattes/` under a hash of the file, the
  mask source (imported masks by name, size and date) and the settings.
  Only the chunks the timeline shows are made; an older chunk plays while
  it is remade.
- Masks: Vision person segmentation (`matte.quality`, default accurate) on
  each frame turned upright and scaled to the matte size (longest side
  `matte.maxSize`), or imported PNGs named by source millisecond, the two
  nearest blended by time. Vision masks then get back
  what moves fast next to the body (`matte.motionFill`): a pixel whose
  brightness, at half the matte size, differs by more than
  `motionThreshold` from both the frame before and the frame after is
  moving now (the wall a hand has just left is not); moving pixels
  connected to the mask within `motionReach` matte pixels are added. Then
  the repair in time: closing in time over `closeSeconds`, and the wide matte as
  the union over `growSeconds`. A chunk decodes `2r + g` extra frames on
  each side, so it equals one pass over the file (tested).
- Measured on 1080p 30 fps test footage: about 75 ms a
  frame with two chunks at once, median overlap of a frame with the one
  before 0.998, lowest 0.956. Vision leaves out the chair but loses the tips
  of fast, blurred fingers; the motion fill gives them back (checked on a
  blurred hand against the wall, nothing added on the wall).
- A chunk file is HEVC, twice as tall as the matte: the tight matte on top,
  the wide one below, each pixel the signed distance to the outline (128 +
  4 per pixel, positive inside, exact transform clamped at 32 px). Cutting
  1 px inside, softening and growing the outline then need one texture read
  and no filtering on the GPU; distances also survive compression far
  better than a hard mask. A sidecar JSON keeps each frame's overlap with
  the frame before and change of area (`matte.status`).
- On the timeline each track with matted clips gets a matte track laid out
  like its clips (cuts, speed); the compositor receives the matte frame
  with the footage frame (tested frame by frame).
- Drawing a depth layer: each pass (back on top of the frame, front below)
  is first drawn alone at its own size and runs through the clip's effects,
  like any layer with effects. The matte of the nearest matted layer below
  it is drawn into a screen-sized texture as output-pixel distances,
  following the clip's transform. The elements cast a shadow on the wall
  behind the person: the alpha of the casting passes at a quarter of the
  size, Gaussian-blurred in two passes, offset, and cut by the person like
  the back pass, so it never falls on him (`matte.shadow`: on or off,
  colour, opacity, offset, blur, which passes cast it). The back pass is cut by
  phi((d - cutInset) / cutSoftness) of the tight matte (or the wide one
  with `matte.cutWith = wide`), the outline fills the band between the
  tight matte and the wide matte grown by the edge radius, the front pass
  goes on top: the same order as a composite made outside, with the shadow
  under the back pass. Edge radius, blink,
  fade and vertical profile come from `matte.edge` and are timed at the
  middle of each frame. Without a matte nothing is cut.
- Export makes the chunks it needs first; their hashes and the matte
  settings are part of the segment hashes.

## 12. MCP server

- The protocol is implemented in the repository (JSON-RPC 2.0 with
  `initialize`, `ping`, `tools/list`, `tools/call`); there is no SDK
  dependency.
- Two transports: HTTP on the loopback interface (`dme serve`), with a bearer
  token generated on first run and kept in the user's settings file, and
  stdio (`dme stdio`) for clients that start servers as child processes.
  Requests from a non-local browser origin are refused.
- Tools and their schemas are generated from the tool catalog, which itself
  generates every write tool from the command registry. MCP tool names use
  `_` where the editor uses `.` (`timeline_split`), because MCP clients accept
  only letters, digits, `_` and `-`. The full list is in
  [mcp-tools.md](mcp-tools.md).
- Every tool is available at all times, whatever the UI shows.
- Results are compact and paginated. Frames are returned as images.
- Several clients may connect. Their commands are ordered by the command bus,
  and the UI shows agent edits as they happen.

## 13. UI

- AppKit window. The timeline is a custom view that draws only the clips in
  view, and the player is an `AVPlayerLayer`, which shows HDR footage in HDR
  on displays that have it (preview range, above). Panels added later may use SwiftUI.
- The MCP server runs inside the app, on the same open project. The window
  follows every change, whoever made it.
- Menus follow the macOS layout: the app, File, Edit, Clip, Timeline,
  Playback, View, Window, Help. Help › Keyboard Shortcuts (⌘/) lists every
  key from the current keymap and the menus.
- Sliders fill from their neutral value (0, or 1 for speed and scale, the
  centre for position), blue towards higher values and red towards lower.
- Colour presets (look profiles) are saved, updated, renamed, deleted and
  applied from the Colour panel; the last one used stays selected across
  launches (a per-viewer UI preference in user defaults).
- Window › Agent Notes shows the notes agents write, as formatted Markdown,
  with search and a way to the clips and time a note is about.
- The window opens centred on the screen. The timeline zooms from 6000 px a
  second (a 60 fps frame 100 px wide) to 0.02 px a second (hours on one
  screen); times show hours from an hour on. Sound shows as CapCut-style
  bars: across sound clips, along the bottom of picture clips.
- Every menu item and key runs a tool from the same catalog agents use. A
  menu item runs its tool directly (not through a key), and its title shows
  the key bound to that tool and those arguments in the current keymap.
- Layout: player and transport (start, frame back, play, frame forward, end)
  on the left, tabs on the right (Media, Clip, Colour, Effects, Accent,
  Words), timeline below. The browser opens as a sidebar tab or its own
  window.
- Panels: Media lists the pool (drag a row onto the timeline, relink,
  remove unused, transcribe); Clip holds speed, sound (gain, mute, fades),
  fit and crop, slip, replace, the footage's person matte, a HyperFrames
  layer's render, status and lint, and the track-wide sound tools (pauses,
  loudness, gaps, join fades); Words shows a transcript at its timeline
  places (click a word to go there, search). History and Settings (every
  setting, and the keymap) are windows, and so is Download from Link
  (File menu, ⇧⌘D, or Media › From link): a post's link, what to get,
  quality, captions and whether to place it; the downloads present, a
  look at one (contact sheet, metadata, loudness, captions), placing it at
  the playhead and moving downloads to the Trash, all through the social
  tools.
- Timeline: track headers have lock, mute and hide buttons (double-click
  the name to rename); markers are flags in the ruler that edges snap to;
  ⌥-drag on the ruler marks a range that Delete removes from every track;
  right-click menus on clips, headers, the ruler and markers. Files
  dropped on the timeline go on that track at that time, footage dropped
  on the picture to the end of the main track, pictures and sound to a free
  overlay or audio track at the playhead.
- The inspector for effects and looks is generated from parameter schemas.
- The keymap maps key chords to tools with fixed arguments; `$playhead` and
  `$selection` are filled in when the key is pressed. The default follows
  CapCut (E-5); a user `keymap.json` next to the settings file replaces it, and
  the `keymap` tools change it.
- The owner sees agent work live: timeline edits, jobs with progress, and the
  browser while an agent drives it (B-4).

### Composition length

An AVComposition ends with its last real media, so a timeline whose end is
still pictures, HyperFrames layers or nothing would stop the player and
refuse seeks early. A one-second black video made once into the cache
(`Filler`) is stretched over the whole timeline on its own track; the
compositor never draws it. A seek made while an edit's rebuild is pending
is kept and clamped to the new length, not the old one.

### Browser host

A `WKWebView` with a persistent data store per profile
(`WKWebsiteDataStore(forIdentifier:)`, ids kept in `browser.profiles`), so
sign-ins survive restarts (B-1). `BrowserHost` (MediaEngine, main actor)
owns the one view; the app shows it in a sidebar tab or its own window, and
without the app it lives in an offscreen window, where it still renders and
takes real clicks (tested). The owner sees every agent step (B-4).

- Reading: a script in an isolated script world lists visible elements
  (through shadow roots) with stable references (`data-dme-ref`), their
  role, name, value and box, plus the page text.
- Acting: clicks are scripted pointer and click events, or with `trusted` a
  real mouse click sent to the view; typing sets field values or inserts
  text into editable areas (Gemini's prompt box), Return is a real key.
  Files reach an upload field through a `DataTransfer`, a drop area through
  drop events, or a file chooser through the panel delegate.
- Results: downloads (a site's own download button gives full size;
  Gemini's page image is a 1024 px preview of a 2048 px result) and large
  images on the page, read as shown (script fetch,
  or a download with the profile's cookies for another site's image);
  downloads land in the cache. A result is saved into the project's
  `images/` folder or a HyperFrames composition's `assets/` (covers); the
  media pool takes only video and sound, so stills stay files.
- `browser.generateImage` runs a whole generation on the owner's image
  site, Google AI Studio (`browser.imageSite`: address, model id, default
  run settings and control names are data). Nano Banana Pro
  (`gemini-3-pro-image`) at 4K by default, chosen through the address.
  Every image gets a new session (`browser.freshSessionPerImage`): the
  site slows down badly from the third image of a chat, and a failed image
  is retried with the whole prompt in a clean chat, never revised in its
  own. The prompt is typed as real key presses and Run is a real click;
  scripted typing and clicks get "Permission denied" (measured). Input
  images go in through the site's own Upload files and file chooser.
  The result is the largest image named "Generated Image" once the Stop
  button is gone (Pro shows draft images while it thinks). An error on
  the page, or a page that does not load, means a fresh try, up to
  `retries` (default 3): Google's image models fail often.
- Tested through MCP, every aspect ratio at 4K: 1:1 4096 x 4096, 9:16 3072 x 5504, 16:9 5504 x 3072,
  4:5 3712 x 4608, 3:4 3584 x 4800, 2:3 3392 x 5056, 3:2 5056 x 3392,
  5:4 4608 x 3712, 21:9 6336 x 2688.
- Downloads land in `browser.downloadFolder` (default the cache); a result
  can be saved into any folder.
- WebKit keeps each program's stores apart: the app and the windowless
  `dme` see different sign-ins for the same profile name. Sign in where
  the agent will work, normally the app.
- `browser.listResults` answers with `pageImages`: a top-level `images` key
  is taken by the MCP layer as pictures for the model.
- Safety: the host refuses to type into a password field; sign-in and
  consent dialogs are the owner's (B-6). Page alerts are answered and
  reported, confirmations answered no. The user agent is Safari's
  (`browser.userAgent`), which the engine is.

### Reference downloads

`social.*` (`MediaEngine/Social`) fetch posts from YouTube, Pinterest,
Instagram and X for agents that need a reference (D-1 to D-5).

- yt-dlp is run as an external command, like HyperFrames: found from
  `downloader.command`, then PATH, then `downloader.searchFolders`
  (Homebrew's folders), with time limits from settings. Its ERROR lines,
  and the warnings that show a sign-in wall, become the error; text from
  `downloader.loginHints` makes it a `locked` error that names
  `downloader.cookiesFromBrowser`, text from `downloader.noVideoHints` sends
  it to the picture fallback.
- One metadata read per download (`-J --skip-download
  --ignore-no-formats-error`); the download then works from that JSON
  (`--load-info-json`), because sites can throttle a second read at
  once. Format choice is data: `downloader.qualities`
  maps names to yt-dlp arguments, H.264 and AAC in MP4 first so
  AVFoundation reads the result; ffmpeg joins picture and sound.
- Items without formats are pictures: each one's largest thumbnail from
  the metadata (Pinterest originals, carousel items), else the page's
  `og:image` and `og:video` tags read with URLSession. The built-in
  browser is not used: it lives on the main actor with a window, and a
  plain page read is enough for these tags.
- A download is a folder per post (`<platform>-<post key>`, the key taken
  from the link so a post always lands in the same place) in the project's
  `downloads/` or the cache, with an `info.json` sidecar and `inspect/`.
  Inspection uses the frame capture of `frame.captureSource`, the sheet
  of `frame.sheet` and the loudness meter of `audio.loudness`.
- Cleanup moves folders to the Trash (`FileManager.trashItem`) and never
  removes media a clip uses unless forced; unused pool entries go first.

## 14. Export

- The timeline is cut into segments of `export.segmentSeconds` (default 2 s)
  on frame boundaries. Each segment is rendered by the same compositor as the
  player and encoded on its own, so it starts with a keyframe.
- A segment is stored in `~/Library/Caches/DanialMCPEditor/export/<project>/`
  under a SHA-256 of everything that affects its frames: the engine version,
  the output format, and for each visual track the clips seen in the
  segment (all their fields, the file's fingerprint, their looks, and the
  code of their effect plug-ins). A segment already there is not rendered
  again, so an interrupted export continues where it stopped (R-3) and after
  an edit only the segments whose frames changed are rendered (R-4). New
  segments are written under a temporary name and renamed when complete.
- Reading starts through `safeStart` (open-GOP video, section 5) and frames
  before the segment are dropped.
- The sound is rendered in one pass with the player's audio mix (gains,
  fades, speed with pitch kept), as AAC or 24-bit PCM.
- Segments and sound are joined into the output without re-encoding. The
  output is written under a temporary name and moved into place when
  finished, so a failed export leaves no half file; a replaced file goes to
  the Trash.
- `export.parallelSegments` (default 2) segments render at once; the hardware
  encoder is the limit (phase 0, test 2).
- Encoders: HEVC Main 10 or H.264 High through VideoToolbox, ProRes 422 HQ or
  4444. Colour tags are written for Rec.709 or BT.2020 HLG.
- The composition renders every output frame (`containsTweening`), so a
  60 fps export of 30 fps footage has 60 distinct frame times, and fades and
  keyframes move every frame.
- Presets are data in the user settings (M-4); shipped: reel, story, lesson,
  youtube, master. Size, frame rate or dynamic range left out of a preset
  mean the project's own.
- Measured with test footage (14 s, 1080p 30):
  lesson preset 2.8 s (5x real time), reel preset (1440x2560 60 fps HLG)
  8.7 s (1.6x), re-export with nothing changed 0.12 s. Exported frame against
  the editor's own frame: mean difference 1.3 of 255, the encoding loss.

## 15. Tests that decide the design

Results of tests 1 to 4 are in [phase0.md](phase0.md).

Each is a small throwaway program run before the feature that depends on it.

| # | Question | Decides |
|---|---|---|
| 1 | Does a 4K 60 fps HEVC timeline with 500 cuts and a speed change play without dropped frames or drift through the composition path? | Composition path or custom engine |
| 2 | Can separately encoded segments be joined without re-encoding and play cleanly, with correct HDR tags? | Segment export as designed |
| 3 | Does an HLG project look identical in the player and in the exported file? | Colour pipeline |
| 4 | Is pitch-preserved speed at 1.22 as clean as the current result? | Built-in time pitch or another algorithm |
| 5 | Headless Chrome or WebKit for HyperFrames: speed, memory, identical frames | Renderer choice |
| 6 | Can the bridge detect a busy Edits, and remove every trace of its own job? | Bridge lifecycle |

## 16. Performance targets

Measured and kept as automated tests. The numbers are
first targets and are tightened after the first measurements. Tests with a
wall-clock limit are named `timed...` and `scripts/swift.sh test` runs them
after the others, one at a time: in parallel with the GPU suites a 4K frame
timed many times longer than alone.

| Area | Target |
|---|---|
| Playback, 4K 60 fps, 500 cuts, one look, one overlay | 60 fps, no dropped frames in 60 s (phase 2: 0 dropped in 20 s, 4K 60, 500 cuts, no look yet) |
| Audio to video offset after cuts and speed change | under one frame |
| Applying one command on a 2,000-clip project | under 16 ms |
| Applying a 500-command batch | under 250 ms |
| Opening a 2,000-clip project | under 1 s |
| Memory while idle with a project open | under 400 MB (phase 2: 108 MB idle, 123 MB playing 4K) |
| Disk written on import | none beyond small analysis caches |
| Export of 2K 60 fps HEVC | faster than real time |

## 17. Build and distribution

- Swift 6 with strict concurrency. Swift Package Manager only: the app
  builds with the Command Line Tools and needs no Xcode.
  `scripts/build-app.sh` assembles and signs `build/Danial MCP Editor.app`. Metal shaders are compiled from source at run time, which
  is also how effect plug-ins load them.
- `scripts/swift.sh` wraps `swift build` and `swift test` and adds the Swift
  Testing paths that the Command Line Tools need.
- Apple Silicon, macOS 26 or later (N-5).
- Not sandboxed, hardened runtime, signed for local use. The app needs to
  read media anywhere the owner keeps it and to start the HyperFrames
  renderer.
- No third-party code. The MCP protocol layer is small and implemented
  here.
- External commands instead of linked code where a tool changes faster
  than the editor: HyperFrames renders compositions, and yt-dlp downloads
  reference media. Site extractors break and are fixed every few weeks,
  so yt-dlp is updated on its own, without a new editor build;
  writing and keeping up extractors for four sites here would be far more
  code than the runner. Both are found and configured through user
  settings, and the editor works without them.
- Machine-specific values (paths, tokens, the Edits connection) live in user
  settings outside the repository (G-1, G-2).

## Still pictures

A picture in the media pool (kind `image`) is an endless source: its clips
last as long as they are placed. The composition builder decodes it once,
upright and at most 4096 px on its longest side, into a BGRA buffer with
straight alpha, and the instruction hands that buffer to the compositor in
place of a track frame; the clip's track carries empty time there. Looks,
effects, keyframes and transforms apply as to video.

## Accent colour

The owner's accent for motion graphics is project data (`project.setAccent`),
picked in the app's Accent panel on the video's own frame. Its derived values
(ink by WCAG contrast on every stop, `--acc-hi` as the first stop mixed
towards white) follow the hyperframes skill's picker exactly (tested against
its JavaScript).

