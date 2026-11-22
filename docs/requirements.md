# Danial MCP Editor: requirements

This is the single source of truth for what the editor must do. Architecture and
the MCP tool list get their own documents and must not restate or contradict
this one. When a requirement changes, it changes here first.

Status: draft, under review by the owner. Nothing is built yet.

Each requirement has an ID. Section 16 lists what is still undecided; nothing in
that section may be implemented on a guess.

## 1. Purpose and scope

A native macOS video editor built for one owner's production workflow. An AI
agent does the work end to end through MCP. The owner watches the result in the
app, corrects by hand where that is faster, and approves.

- **S-1 MCP-first.** MCP is the primary interface and comes before the UI in
  every design decision. A capability is designed as an MCP command first and
  the UI is built on top of it. The UI is still complete, correct and up to
  macOS standards; MCP-first sets the order of priority, it does not excuse a
  weak UI.
- **S-2** The editor covers the owner's own workflow only. A feature that the
  workflow does not use is out of scope.
- **S-3** The editor replaces Instagram's Edits app and CapCut for this
  workflow, with one exception: transcription (section 8).
- **S-4** Out of scope: a text or caption tool (on-screen text is made in
  HyperFrames by the agent), a licensed music library, a stock effect
  catalogue, templates, social publishing, collaboration, Intel Macs, any
  platform other than macOS.

Work that needs the editor: talking-head Reels and posts, course lessons, long
YouTube videos, recorded platform tutorials. Ads, stories, covers and short
tutorial clips are pure HyperFrames renders today; they benefit from the
HyperFrames integration (section 9) and the image browser (section 13) but need
no cutting.

## 2. Non-negotiables

- **N-1 Performance.** Light on CPU, GPU, memory and disk. No freezing, no lag
  and no audio drift on long timelines or timelines with hundreds of cuts.
- **N-1a Load split between CPU and GPU.** Heavy pixel work (decoding and
  encoding on the media engines, colour, effects, compositing) runs on the
  GPU, so the CPU stays free for the editor, the timeline and audio. Work
  moves to the GPU only when a measurement shows a real gain: lower CPU load,
  less heat, faster renders or playback. Work that gains nothing there, or
  costs more in transfers, memory or file size than it saves, stays on the
  CPU.
- **N-2 Full MCP parity.** Everything the app can do is available through MCP,
  so an agent can take a project from empty to final export without the UI.
- **N-3 Transcription accuracy.** Transcription must match what the
  Edits captions service produces today. Every other step depends on it.
- **N-4 No lost work.** Autosave, crash recovery and interruptible renders.
- **N-5 Native.** Written for macOS with Apple's own frameworks. No
  cross-platform UI layer. Apple Silicon only. Minimum system: macOS 26.
- **N-6 No quality loss.** Exports keep the source frame rate, resolution,
  bit depth and dynamic range unless the owner asks otherwise.

## 3. Formats

- **F-1 Resolutions**, for input and output: 1080p, 2K (1440p), 4K (2160p), and
  custom sizes.
- **F-2 Aspect ratios:** 9:16 and 16:9.
- **F-3 Frame rates:** 30 and 60 fps, for input and output.
- **F-4 Dynamic range:** SDR and HDR are both fully supported, for input,
  preview and export. Raw footage looks in the preview as it does, on the
  same display and whatever the project's range, in the editor the owner
  chooses: CapCut and plain players (default) or Edits in an SDR project.
  Those two differ, so it is a setting (`preview.gamma`).
- **F-5 Audio** is processed and exported at the highest standard quality the
  target format allows.
- **F-6** Format handling follows current best practice for each delivery
  target (Instagram Reels, YouTube, course platform).

Formats:

| Output | Size | fps | Video | Audio |
|---|---|---|---|---|
| Reel / Short | 1440x2560 | 60 | HEVC 10-bit, HLG | AAC stereo |
| Story, ad | 2160x3840 | 60 | H.264, Rec.709 | AAC 48 kHz stereo |
| Course lesson | 1920x1080 | 30 | H.264, Rec.709 | AAC 48 kHz stereo |
| Motion layer | 1080x1920 | 60 | HEVC or ProRes 4444 with alpha | none |

Camera footage is HEVC, recorded at 4K 60 fps or 1080p 30 fps.

## 4. Command layer and MCP

- **M-1** Every action is a command. Buttons, keyboard shortcuts and MCP tools
  all call the same commands. Nothing exists that only the UI can do.
- **M-2** Every command is undoable.
- **M-3** MCP exposes read tools as well as write tools: project state,
  timeline, clip properties, rendered frames, audio levels and colour
  measurements, so an agent can check its own work.
- **M-4** Options and values live in settings or data files, not in code:
  keymap, colour profiles, export presets, effect list, cut rules.
- **M-5** Turning something off means a setting switched off. The capability
  stays.
- **M-6 Agent onboarding.** One tool call gives an agent everything it needs
  to start: the rules, the tool map, the open project in brief and its notes.
  The MCP server's instructions point to it, and the full agent guide is a
  tool too.
- **M-7 Agent notes.** Each project keeps markdown notes that agents and the
  owner read and write through MCP: the spec of the edit, progress, decisions
  and notes on clips or time ranges. They are light to read (an index with
  one line each, and single sections on demand) and record the project
  revision they were written at, so an agent picking up the work sees what
  changed since, without going through the whole video again.

## 5. Manual editing

The agent does most of the work. The owner needs fast manual cutting for the
cases where explaining takes longer than doing.

- **E-1** A player and a timeline with scrubbing and clip movement.
- **E-2** Transport shortcuts: Space for play and pause, jump to project start
  and end, jump to the previous and next clip edge.
- **E-3** Split at the playhead: Cmd+B (the tracks of the selected clips, or the main track when none is selected).
- **E-3a** CapCut's other keys: Cmd+C / Cmd+V copy and paste at the playhead, Cmd+D duplicate, Cmd+A select all, Esc clear, M marker, , and . nudge one frame, Cmd+= / Cmd+- zoom, Shift+Z fit.
- **E-4** Delete from the playhead back to the clip start: Q. Delete from the
  playhead forward to the clip end: W.
- **E-5** Shortcuts are read from a keymap file. The default keymap matches
  CapCut's standard keys.
- **E-6** Speed change that keeps the pitch of the voice.
- **E-7** Zoom and position by transform keyframes.
- **E-8** Blur on footage.
- **E-9** A short audio fade at every cut join.
- **E-10** Automatic silence removal driven by rules kept in settings (pause
  length, silence threshold, padding kept before and after words).

## 6. Colour and light

- **C-1** The colour tools are the four tabs of the Edits Adjust panel that
  the owner uses, copied control for control and in the same order.
  - **Adjust** (each -100 to 100): exposure, clarity, highlights, shadows,
    contrast, brightness, whites, blacks, saturation, vibrance.
  - **White balance** (each -100 to 100): temperature, tint.
  - **HSL**: hue, saturation and luminance (each -100 to 100) for eight
    colour bands: red, orange, yellow, green, cyan, blue, purple, magenta.
  - **Style** (each 0 to 100): sharpen, noise reduction, fade, vignette,
    grain.

  The panel also has an on/off switch for the whole look, a reset, and a
  save button for profiles (C-2). The other Edits colour tools (colour
  wheels, tone curves, filters, LUTs) are left out.

  The numbers are the editor's own scale and need not give the same picture
  as the same number in Edits or CapCut. Each control must do exactly its own
  job and nothing else, and this is tested on rendered frames.
- **C-1a Custom colour in HSL.** Besides the eight fixed bands, the owner or
  an agent can pick any colour, from a colour picker or straight from the
  picture, and adjust hue, saturation and luminance for that colour only.
  Typical use: skin tone or eye colour. A look can hold several picked
  colours.
- **C-2** Profiles: a finished look can be saved, loaded later and applied to
  a clip.
- **C-3** Scoped application. A look applies to chosen clips or tracks only,
  for example the camera footage, and never touches motion graphics or other
  layers.
- **C-4** Full manual control in the UI.
- **C-5** Full agent control through MCP, used when the owner asks for it.
  The agent must be able to match a reference such as a film, a scene or
  another clip, which needs tools for reading frames and colour statistics.

## 7. Audio

- **A-1** Several audio tracks: voice, music, sound effects.
- **A-2** Any audio file can be placed on the timeline as a music clip. The
  agent brings music from outside.
- **A-3** Sound effects are separate timeline elements that never alter the
  voice track.
- **A-4** Audio stays in sync with picture after any number of cuts and speed
  changes, in preview and in export.
- **A-5** Audio level analysis is available as a tool. Cut points are placed
  from audio levels, because word timestamps from transcription are not exact.

## 8. Transcription

- **T-1** Word-level transcription with timings, accurate for the spoken language.
- **T-2** For now the editor gets transcripts by driving the Edits app through
  its local MCP server. Only an audio file is sent, never video.
- **T-3** The bridge never disturbs other work in Edits. Before a job it
  checks whether Edits is already in use by the owner or by another agent (an
  open project, a running export or job). If it is, the bridge waits and does
  not open, close, select or change anything there.
- **T-3a** The bridge leaves nothing behind (if Edits was already running and
  idle, it is left running, since someone else started it). Once the transcript is received
  it removes the project, the imported audio and every file Edits generated
  for the job, then quits Edits. No leftover projects, no generated junk, no
  process left running. It removes only what its own job created.
- **T-4** The transcript is stored in the editor's own project and linked to
  the timeline, so it follows cuts and speed changes.
- **T-5** Local speech models are not used unless a test shows they match the
  accuracy in T-1.

## 9. HyperFrames

- **H-1** HyperFrames compositions are a layer type inside the editor.
- **H-2** An agent builds, edits, renders and places a composition entirely
  through the editor's MCP.
- **H-3** In the UI a HyperFrames layer is view-only.
- **H-4** A change to one part of a composition re-renders that part only.
- **H-5** The rendering engine is whichever is lighter and faster on the
  target machine, as long as the output is identical. Decided by test 5:
  the HyperFrames command line (headless Chrome).

## 10. Preview

- **P-1** The owner reviews work by playing it in the app, with correct
  picture, sound, colour and every layer. No file is exported for review.
- **P-2** Preview stays responsive on heavy projects without bulky proxy
  files.

## 11. Rendering and export

- **R-1** An agent can run the final export through MCP with full control of
  format, resolution, frame rate and dynamic range. This is the preferred path.
- **R-2** The UI offers the same export.
- **R-3** A render that is interrupted loses no finished work.
- **R-4** After an edit, only the affected section is rendered again.
- **R-5** Export is as fast as the hardware allows and uses hardware encoding
  where it does not cost quality.

## 12. Effects

- **X-1** The first version ships a small fixed set: fade in, fade out, and
  the intro and outro effects the workflow uses.
- **X-2** Effects are plug-ins. Adding one needs no change to the core, and
  the owner and the agent can both switch between them.
- **X-3** A person matte (subject mask) is built in-house at a later stage.
  It comes from Apple Vision inside the editor or from masks imported from
  elsewhere (SAM 3 from Edits), is repaired in time so it errs only on the
  safe side, reports its stability, and lets a HyperFrames composition put
  elements behind the person with a lit outline (decided in phase 8).
  It has lower priority than everything above.

## 13. Built-in browser for image generation

This is an optional extra with the lowest priority. It is built last.

- **B-1** The app includes a real, lightweight web browser, shown in a sidebar
  or on its own page. The owner can sign in to any site, and sessions persist.
- **B-2** Through MCP an agent has full control of that browser: open a new
  session, enter a prompt, attach input files, set model, output size and
  other options, start generation and export the results.
- **B-3** The agent can view the results, decide whether they are usable,
  revise the prompt and generate again in a fresh session.
- **B-4** The owner sees everything the agent does in the browser as it
  happens, including the results.
- **B-5** Results can be used directly for covers and other images in the
  workflow.
- **B-6** Sign-in is always done by the owner. The agent never handles
  credentials.

## 14. Reference downloads

- **D-1** Media from YouTube, Pinterest, Instagram and X is downloaded by
  link, from the app and entirely through MCP: video, sound, and the
  pictures of photo posts, carousels and image pins (every item).
- **D-2** An agent can read a post's metadata (title, uploader, date,
  description, length, counts, formats, subtitle languages) without
  downloading it.
- **D-3** An agent can look at a download without leaving the editor: a
  contact sheet, single frames, the subtitle text and the loudness.
- **D-4** Downloads can be added to the media pool, are listed with their
  sizes, and are moved to the Trash when no longer needed; a download that
  clips use is kept unless the agent insists.
- **D-5** Items that need a signed-in session use the owner's browser
  sign-in only when the owner turns it on in settings. The agent never
  handles credentials.

## 15. Reliability

- **L-1** Projects save automatically and continuously.
- **L-2** A crash, a forced quit or a long session loses no work.

## 16. Repository rules

- **G-1** The repository is public. Nothing private goes in: no machine
  details, network details, account names, tokens or personal paths.
- **G-2** Secrets and local-only material live in git-ignored folders.
- **G-3** Footage, renders and editor projects are user data and are not
  committed.

## 17. Open decisions

None at the moment. The HyperFrames engine (H-5) was decided by test 5 in
[phase0.md](phase0.md).
