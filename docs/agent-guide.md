# Driving the editor through MCP

Guide for agents that edit video with Danial MCP Editor. Everything the editor
can do is a tool; there is no step that needs the UI.

## Connect

Build the server once:

```bash
scripts/swift.sh build -c release --product dme
```

Then either let the client start it (stdio):

```bash
claude mcp add dme -- /path/to/repo/.build/release/dme stdio
```

or run it yourself and connect over HTTP:

```bash
.build/release/dme serve
```

`dme info` prints the address, the settings file and the exact commands. The
HTTP bearer token is `mcp.token` in the settings file; it is never returned by
any tool.

Only one process can have a project open. When the app is running, connect
to its server over HTTP: it holds the open project and the owner sees your
edits live in the window. Start `dme` only when the app is not running.

## Start every session with `agent_onboard`

One call returns the rules, a map of all tools, the open project in brief,
its notes index, the `spec` and `progress` notes in full, and the commands
applied since the newest note was written. Read that instead of walking the
whole timeline or watching the video. `agent_guide` returns this guide, or
one section of it.

## Notes: your memory between sessions

Each project keeps markdown notes (`notes_*` tools), inside the project.

- **spec**: what the edit must become: goal, format, style, the owner's
  rules for it. Read it first and keep it current.
- **progress**: what is done, what is next, open questions. Rewrite it
  before you stop, so the next session starts from it.
- Anything else: decisions, notes on a clip or a stretch of time (pass
  `clips`, `from`, `to`), things to check.
- `notes_list` shows every note in one line; read only what you need, one
  section at a time with `section`. `notes_write` with mode `section`
  changes one part without rewriting the rest.
- Each note records the project revision it was written at. If the project
  moved on, `agent_onboard` lists the commands since; `history_list` with
  `since` gives the details.

## Basics

- **Names.** Tools are named `domain_verb`: `project_create`, `clip_add`,
  `timeline_split`.
- **Time** is seconds on the timeline, snapped to the project's frame grid.
  Source times (`sourceStart`, `sourceDuration`) are seconds in the media file.
- **Ids.** Every object has an id. Tools take ids, never a selection. You may
  choose ids yourself (`id` on `clip_add`, `track_add`, `marker_add`), which
  lets one batch refer to things it creates.
- **Revisions.** Every change returns the new `revision` and the commands as
  applied, with times snapped and new ids filled in. Pass `ifRevision` to
  refuse the change if someone else edited in between.
- **Dry run.** Pass `dryRun: true` to check a change and see how it would be
  applied, without making it.
- **Undo.** Every change is undoable: `history_undo`, `history_redo`,
  `history_revertTo`. `history_list` shows what changed and when.
- **Nothing to save.** Every confirmed change is already on disk. A crash or a
  kill loses nothing; `project_open` recovers.
- **Errors** come back as tool errors with a code (`not_found`, `invalid`,
  `conflict`, `locked`, `stale_revision`, `io`) and a message that says what
  to change.

## A typical start

1. `project_create` with `path` and a `preset` (`reel`, `youtube`, `lesson`;
   `settings_get` lists them), or `project_open`.
2. `media_import` with file paths. Files are referenced, never copied.
3. `clip_add` on the main track (its id is in `project_get`).
4. Cut with `timeline_split`, `timeline_deleteToEdge`, `timeline_deleteRange`.
5. Read back with `timeline_get` or `clip_list`.

## Looking at the result

- `frame_capture` returns the rendered frame at a time as an image, drawn
  exactly as playback and export draw it. `frame_sheet` returns a grid of
  frames over a range. Use them to check every visual change.
- `frame_captureSource` shows a media file before any editing.
- `player_seek`, `player_play`, `player_jump` move the playhead the owner sees.

## Sound, cuts and transcripts

- `audio_findSilence` lists the pauses the cut rules would remove;
  `audio_applySilenceCuts` removes them in one undoable step and sets the
  join fades. Rules come from `settings_get` (`cutRules.silence`) and can be
  overridden per call with `rules`.
- `audio_normalize` brings the voice track to the loudness target, never past
  the peak ceiling. `audio_loudness` measures a file or the timeline.
- `transcript_create` transcribes through the Edits app as a job: wait with
  `job_wait`. If Edits is in use the job waits for it; it never touches the
  user's Edits work. `transcript_import` loads an existing JSON transcript.
- `transcript_get` returns words at their current timeline times, so after
  cuts and speed changes the times are still right. `transcript_find` finds
  a phrase.
- Sound effects are their own clips on an audio track (`track_add` kind
  `audio`, then `clip_add` with the sound file): they never change the voice.
  `clip_setAudio` sets gain and fades.
- `clip_detachAudio` puts clips' sound on an audio track and mutes the
  pictures, so sound and picture can be cut apart (J and L cuts).
- `audio_record` records a voice-over from the microphone onto a Voice
  track where recording starts (the owner talks; you start and stop it only
  when he asks).

## Colour and light

Colour is the owner's work. Change it only when asked.

- A look holds the Adjust, White Balance, HSL and Style values. Create it with
  `look_create`, use it with `look_assign` on the camera clips or the main
  track, never on graphics. `look_update` changes every clip that uses it.
- To match a reference (a film still, another clip): `color_compare` gives the
  frame's and the reference's statistics and their difference; change the
  look, check again, repeat. `frame_capture` shows the result.
- `color_sample` reads a colour (for example skin) from the camera picture;
  `look_addPickedColor` then changes only that colour.
- `look_saveProfile` keeps a finished look for later projects;
  `look_loadProfile` brings it back.

## Effects and zoom

- `effect_catalog` lists what is installed and each effect's parameters.
  `effect_add` puts one on clips: `in` effects at the clip start, `out` at
  its end, filters for the whole clip. `effect_set` changes it.
- Zoom and moves are keyframes: `clip_setKeyframes` with property `scale`
  (or `x`, `y`, `rotation`, `opacity`) and a list of `{time, value, easing}`
  in timeline seconds. They stay on the same picture if the clip is trimmed,
  split or sped up later.
- Check with `frame_sheet` over the clip, or `frame_capture` at a moment.
- `clip_freezeFrame` holds the frame at a time for a while (one source
  frame stretched: same look, matte and colour, silent).
- Pictures (PNG, JPEG, HEIC) import like video (`media_import`) and go on
  any picture track; give `sourceDuration` for their length.

## HyperFrames

- `hf_create` makes a composition inside the project; write its
  `index.html` and `compositions/*.html` with `hf_writeFile`. The usual
  HyperFrames model applies: a root with `data-composition-id`, size, fps and
  duration; elements and sub-compositions with `data-start` and
  `data-duration`; each GSAP timeline registered in `window.__timelines`.
- `hf_check` lints it, `hf_snapshot` shows a frame. `hf_place` puts it on an
  overlay track; `hf_render` renders it as a job and the timeline picks the
  slices up.
- Fix one part at a time: put each scene in its own sub-composition. A
  change re-renders only the slices that show it (`hf_status`).
- Big binary assets (fonts, logos) can be copied into the folder on disk;
  `hf_get` shows where it is.

## Elements behind the person

- Turn the matte on for the footage: `media_setMatte` with `vision`, or
  `matte_import` a folder of SAM 3 masks from Edits. Then `matte_generate`
  and wait for the job.
- Read `matte_status` before using it, and look at its worst frames with
  `matte_snapshot`. A matte that blinks, loses a hand or takes in the chair
  is not used: import better masks or keep elements away from that moment.
- Write the composition with an element `#back` (behind him) and `#front`,
  plus the CSS `html.pass-back #front, html.pass-front #back { display: none; }`.
  `const EDGE = [[start, end]]` lights his outline in those windows. Place
  it on a track above the footage; `hf_render` renders both passes.
- The elements cast a light shadow on the wall, never on him: tune it with
  `settings_set` under `matte.shadow` (`enabled`, `opacity`, `offsetX`,
  `offsetY`, `blur`, `color`, `from` = back, front or both). Clip effects
  work on depth compositions like on any clip.
- Fast hands blur. Vision mattes add back what moves fast next to his body
  (`matte.motionFill`, on by default); if a fingertip is still cut, raise
  `matte.motionReach`, lower `matte.motionThreshold`, or set
  `matte.cutWith` to `wide`.

## Accent colour for motion graphics

- The owner picks the accent himself in the app's Accent panel, on the
  video's own frame (colour wells with an eyedropper, solid or gradient, live
  preview of the kit's shapes, contrast shown). Never choose, propose or rank
  a colour yourself; when `accent_get` returns none, ask him to pick.
- `accent_writeCSS` puts it into a composition as `accent.css`; link it from
  `index.html`. `accent_export` writes the skill's `accent_pick.json`.

## The built-in browser (image generation)

- `browser_open` with a layout (`sidebar` or `window`) so the owner watches.
  The home page is Google AI Studio; profiles keep their own sign-ins.
- Use the app's browser (its sign-ins are not shared with `dme`).
- When a page asks to sign in or for consent, stop and ask the owner to do
  it in the browser. Never type a password.
- For an image, call `browser_generateImage` (a job) with the whole prompt,
  input images and `aspectRatio` (1:1, 9:16, 16:9, 3:4, 4:3, 2:3, 3:2, 4:5,
  5:4, 21:9 and more). It runs on Google AI Studio with Nano Banana Pro at
  4K and retries Google's errors by itself. Look at the saved file. If it
  is wrong, call it again with the whole improved prompt: it opens a fresh
  session. Never ask for changes in the same chat. The picture also goes into
  the media pool (`mediaId` in the result, `addToPool` false to skip), so
  `clip_add` puts it on the timeline (5 s unless you give `sourceDuration`).
- For anything else, `browser_read` gives element references. Type the prompt into the prompt
  box (`browser_type`), attach input images (`browser_attachFiles`), pick the
  model and size with clicks, send, then `browser_waitFor` the result.
- `browser_listResults` and `browser_capture` to look. For full size click
  the site's own download button (Gemini: "Download full size image", 2048
  px; the image on the page is a 1024 px preview), `browser_waitFor` the
  download, then `browser_saveResult` it by name into the project (or a
  cover composition's assets). For another try from a clean start, `browser_newSession`.

## References from social media

When you need an example (a style, a concept, an edit to learn from), fetch
it, look at it, use it, and clean up:

1. `social_info` with the link shows what the post is (title, uploader,
   length, formats, caption languages) before anything is downloaded.
2. `social_download` (a job; `job_wait` it). `what: images` for pictures
   only, `subtitles: true` for captions, `import: true` only when the
   reference goes on the timeline. Photo posts and carousels give every
   picture.
3. `social_inspect` with the download id: the contact sheet comes back as an
   image; ask for `frames` or `times` to save single frames, and read the
   subtitle text, description and loudness it returns.
4. Use it: describe what you take from it, put frames into a HyperFrames
   composition's assets, or place the imported clip.
5. `social_cleanup` with its id when done. It refuses a download that clips
   use; remove those clips first (`force` only when the owner agrees).

A `locked` error means the site wants a sign-in. Tell the owner which item;
only he decides to set `downloader.cookiesFromBrowser`. Never change it
yourself.

## Export

- `export_listPresets` shows the formats (reel, story, lesson, youtube,
  master). `export_start` with `path` and `preset` runs as a job; any field
  can be overridden (size, frame rate, dynamic range, codec, bit rate).
- Follow it with `job_wait` or `export_status`. If it stops, run the same
  export again: finished segments are reused. After a small edit, exporting
  again renders only what changed.
- `export_verify` checks the file: frames, duration, codec, colour tags,
  sound, and whether the duration matches the project.

## Many edits at once

`batch_apply` takes a list of `{"name": "clip_add", "args": {...}}` and applies
them as one atomic step: one revision, one undo, and if any command fails,
nothing is applied. Use it for anything above a handful of edits; 2,000 clips
in one batch take about a quarter of a second.

## Editing rules worth knowing

- A track never has overlapping clips. `clip_add` and `clip_move` use free
  space by default (`mode: place`); `mode: insert` pushes later clips to make
  room.
- Deleting on the main track closes the gap (ripple). Other tracks keep their
  timing unless told otherwise, so music and sound effects stay where they
  were placed.
- Locked tracks refuse every edit until `track_set` unlocks them.
- A clip's speed is the ratio of its source length to its timeline length.
  Splitting never makes the timeline drift.
