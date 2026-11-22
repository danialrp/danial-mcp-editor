# Danial MCP Editor: MCP tools

The tools an agent uses to run the editor. They are generated from the command
and query registries described in [architecture.md](architecture.md), so this
list and the app's menus always describe the same capabilities. Requirement
IDs point to [requirements.md](requirements.md).

Status: built through phase 2: app, project, history, batch, settings,
keymap, media, timeline structure, clip properties (except keyframes),
playback, frames, analysis, transcription, jobs and colour. `app_info` lists what the running build has.
The rest are designed and fixed when their phase in [roadmap.md](roadmap.md)
is implemented.

## Conventions

- **Names** are `domain.verb` inside the editor. Over MCP the dot becomes an
  underscore (`timeline.split` is the tool `timeline_split`), because MCP
  clients accept only letters, digits, `_` and `-`.
- **IDs.** Every project object has a stable ID. Tools take IDs, never a
  selection.
- **Time** is in seconds on the timeline unless a parameter is named
  `source...`. Values snap to the project frame grid, and the result reports
  the snapped value.
- **Revision.** Every write returns the new project revision. A write may
  pass `ifRevision`; if the project has moved on, the call fails and changes
  nothing.
- **Dry run.** Every write accepts `dryRun` and then returns what it would
  change.
- **Errors** carry a code, a message and the offending parameter.
- **Lists** are paginated with `limit` and `cursor`.
- **Jobs.** Long work returns a `jobId` at once. See the job tools.
- **W** marks a tool that changes the project and is undoable. **R** marks a
  read.

## Agents and notes

| Tool | | Purpose |
|---|---|---|
| `agent.onboard` | R | Start here: rules, tool map, open project in brief, notes index, spec and progress in full, commands applied since the notes were written (M-6) |
| `agent.guide` | R | The full agent guide, or one section of it |
| `notes.list` | R | Notes with a one-line summary, clips and range they are about, revision written at; stale clip ids flagged (M-7) |
| `notes.read` | R | A note, or one section by heading |
| `notes.write` | M | Replace, append or replace one section; records the current revision |
| `notes.find` | R | Search all notes |
| `notes.remove` | M | Move a note to the Trash |

## App and project

| Tool | | Purpose |
|---|---|---|
| `app.info` | R | Version, capabilities, loaded effects, presets, settings paths |
| `project.list` | R | Recent and open projects |
| `project.create` | W | New project with canvas size, frame rate and dynamic range (F-1 to F-4) |
| `project.open` / `project.close` | W | Open or close a project |
| `project.get` | R | Summary: settings, duration, track list, revision |
| `project.setSettings` | W | Change canvas, frame rate or dynamic range |
| `project.duplicate` | W | Copy a project |
| `project.trash` | W | Move a project to the Trash |
| `history.list` | R | Applied commands with their revisions |
| `history.undo` / `history.redo` | W | Step through history (M-2) |
| `history.revertTo` | W | Return to an earlier revision |
| `batch.apply` | W | Apply a list of commands as one atomic, single-undo step |
| `events.subscribe` | R | Stream of project changes and job progress. Not built yet: until then `history.list` with `since` gives the changes after a revision |

## Settings and keymap

| Tool | | Purpose |
|---|---|---|
| `settings.get` / `settings.set` | R / W | Read or change any setting, including cut rules (M-4) |
| `keymap.get` / `keymap.set` | R / W | Read or change key bindings (E-5) |
| `keymap.reset` | W | Back to CapCut's keys |

## Media

| Tool | | Purpose |
|---|---|---|
| `media.import` | W | Add files to the media pool by reference. Nothing is copied. Video, sound and still pictures (PNG, JPEG, HEIC...): a picture is an endless source, placed for 5 s unless given a length, transparency kept |
| `media.list` / `media.get` | R | Assets with probed properties |
| `media.probe` | R | Properties of a file that is not imported |
| `media.relink` | W | Point an asset at a moved file |
| `media.remove` | W | Remove an unused asset from the pool |

## Timeline structure

| Tool | | Purpose |
|---|---|---|
| `timeline.get` | R | Tracks and the clips in a time range |
| `track.add` / `track.remove` / `track.reorder` | W | Manage tracks (A-1) |
| `track.set` | W | Name, mute, hide, lock, default look |
| `clip.add` | W | Place an asset range on a track at a time |
| `clip.get` / `clip.list` | R | One clip in full, or clips matching a filter (track, asset, time range) |
| `clip.move` | W | Move in time or to another track |
| `clip.trim` | W | Change the in or out point |
| `clip.slip` | W | Shift the source range under a fixed clip |
| `clip.remove` | W | Remove clips, with or without closing the gap |
| `clip.replaceMedia` | W | Swap the asset and keep position and settings |
| `clip.duplicate` | W | Copy clips |
| `clip.copyTo` | W | Paste: copies at a time, keeping tracks and spacing; inserted on the main track |
| `clip.nudge` | W | Move clips by whole frames |
| `clip.detachAudio` | W | Extract audio: the clips' sound onto an audio track as its own clips, the originals muted (J and L cuts) |
| `clip.freezeFrame` | W | Hold the clip's frame at a time for a while: one source frame stretched, with the look, the transform as shown and the person matte; silent |
| `timeline.split` | W | Split at a time on given tracks (E-3) |
| `timeline.deleteToEdge` | W | Remove from a time to the start (`side: left`, key Q) or end (`side: right`, key W) of the clip under it and close the gap (E-4) |
| `timeline.deleteRange` | W | Remove a time range and close the gap |
| `timeline.closeGaps` | W | Close empty spaces on a track |
| `marker.add` / `marker.list` / `marker.remove` | W / R / W | Timeline markers |

## Clip properties

| Tool | | Purpose |
|---|---|---|
| `clip.setSpeed` | W | Constant speed with pitch kept (E-6) |
| `clip.setTransform` | W | Position, scale, rotation, opacity, crop |
| `clip.setKeyframes` | W | Replace the keyframes of x, y, scale, rotation or opacity (E-7); times in timeline seconds, stored in source time |
| `clip.removeKeyframes` | W | Remove keyframes, for one property or all, optionally in a range |
| `clip.setAudio` | W | Gain, mute, fade in and out |
| `timeline.setJoinFades` | W | Apply the short audio fade at cut joins (E-9) |

## Playback and review

| Tool | | Purpose |
|---|---|---|
| `player.play` / `player.pause` / `player.toggle` / `player.seek` | R | Transport. Not recorded in history |
| `player.step` | R | Move by whole frames |
| `player.state` | R | Playhead, playing state, length, revision shown, dropped-frame count, preview range and gamma (`preview.gamma`: `video` or `edits`), and whether the display has HDR |
| `player.jump` | R | To start, end, previous or next clip edge (E-2) |
| `frame.capture` | R | The rendered frame at a time as export draws it (not in the preview range), as an image, at a chosen size |
| `frame.sheet` | R | A contact sheet of frames over a range |
| `frame.captureSource` | R | A frame of an asset before any processing |

## Voice-over

| Tool | | Purpose |
|---|---|---|
| `audio.record` | W | Record the microphone (start, stop, toggle, status; key R): the take goes on a Voice track where recording started, in one undo step; the timeline plays meanwhile |

## Analysis

| Tool | | Purpose |
|---|---|---|
| `audio.levels` | R | Level envelope of a media file (A-5) |
| `audio.loudness` | R | Integrated and short-term loudness, true peak |
| `audio.findSilence` | R | Proposed cuts from the cut rules (E-10) |
| `audio.applySilenceCuts` | W | Apply proposed cuts as one batch |
| `audio.normalize` | W | Set clip gains to reach a loudness target |

## Transcription

| Tool | | Purpose |
|---|---|---|
| `transcript.create` | job | Transcribe an asset or a range through the bridge (T-1, T-2) |
| `transcript.get` | R | Words with source times and current timeline times (T-4) |
| `transcript.list` / `transcript.remove` | R / W | Manage stored transcripts |
| `transcript.find` | R | Find a word or phrase and return its times |
| `transcript.import` | W | Load a transcript from a JSON file (the shape the current Edits tool writes is accepted) |
| `transcript.remove` | W | Remove stored transcripts |
| `bridge.status` | R | Whether Edits is running, in use, or free (T-3) |

## Colour

| Tool | | Purpose |
|---|---|---|
| `look.create` / `look.update` | W | Create a look or set any of its parameters (C-1) |
| `look.get` / `look.list` | R | Looks in the project |
| `look.assign` | W | Attach a look to clips or to a track, or clear it (C-3) |
| `look.remove` | W | Delete a look from the project |
| `look.saveProfile` | W | Save a look to the owner's profile library (C-2) |
| `look.renameProfile` | M | Rename a saved profile |
| `look.deleteProfile` | M | Move a saved profile to the Trash; looks already in projects stay |
| `look.listProfiles` / `look.loadProfile` | R / W | Use a saved profile |
| `look.addPickedColor` / `look.updatePickedColor` | W | Add or change a custom HSL colour, given as #RRGGBB (C-1a) |
| `look.removePickedColor` | W | Remove a custom HSL colour |
| `color.sample` | R | The colour at a point of a frame, without looks by default |
| `color.stats` | R | Histogram, waveform percentiles and averages for a frame or a region (C-5) |
| `color.compare` | R | Differences between a timeline frame and a reference image |

## Effects

| Tool | | Purpose |
|---|---|---|
| `effect.catalog` | R | Installed effects with kinds, parameters and durations; plug-in folders that failed and why (X-2) |
| `effect.add` | W | Add an effect to clips; parameters checked against the manifest, defaults filled in |
| `effect.set` | W | Change parameters, duration or on/off, or swap to another effect of the same kind |
| `effect.remove` / `effect.reorder` | W | Manage a clip's effects; they run first to last |
| `effect.reload` | M | Rescan the effect folders |

## HyperFrames

| Tool | | Purpose |
|---|---|---|
| `hf.create` | W | New composition folder with size, frame rate and length, added to the media pool (H-1) |
| `hf.list` / `hf.get` | R | Compositions; one composition's files, root settings, sub-compositions and slices |
| `hf.readFile` / `hf.writeFile` / `hf.removeFile` | R / M | Edit composition files (H-2); a write reports which slices went stale |
| `hf.refresh` | W | Pick up an index.html changed on disk (size, frame rate, length) |
| `hf.check` | R | HyperFrames lint |
| `hf.snapshot` | R | A composition frame at a time, as an image with transparency |
| `hf.place` | W | Put a composition on the timeline as a layer |
| `hf.render` | job | Render slices that are not current, or only given ones (H-4) |
| `hf.status` | R | Each slice: range and current, stale or missing |

## Accent colour (motion graphics)

| Tool | | Purpose |
|---|---|---|
| `project.setAccent` | W | Record the owner's pick: solid or two-stop gradient, angle, light variant. Agents never choose a colour |
| `accent.get` | R | The pick with --acc, --acc2, --acc-hi, --acc-ink, contrasts (4.5 reads well) and the CSS block |
| `accent.writeCSS` | M | Write `accent.css` (:root variables) into a composition |
| `accent.export` | M | Write the hyperframes skill's `accent_pick.json` |

## Person matte

| Tool | | Purpose |
|---|---|---|
| `media.setMatte` | W | Turn a footage file's matte on (`vision` or `imported`) or off (X-3) |
| `matte.import` | W | Copy mask PNGs named by source millisecond (SAM 3 from Edits) into the project and use them |
| `matte.generate` | job | Make the chunks the timeline shows that are not made yet |
| `matte.status` | R | Chunks and their state, stability (overlap with the frame before, area change) and the worst frames with their timeline times |
| `matte.snapshot` | R | Source frames with the tight (green) and wide (red) outlines drawn |

## Export

| Tool | | Purpose |
|---|---|---|
| `export.listPresets` | R | Shipped and saved presets |
| `export.savePreset` | M | Store a preset, starting from another and changing fields |
| `export.start` | job | Export with a preset, any field overridden (R-1); reuses finished segments |
| `export.status` | R | Progress, current segment, and the report when done (segments rendered and reused, frames, timings) |
| `export.verify` | R | Check a file: codec, size, frame rate, frame count, duration, colour tags, bit depth, sound, match with the project |
| `export.cacheInfo` / `export.clearCache` | R / M | Size of the segment cache; move it to the Trash |

## Jobs

| Tool | | Purpose |
|---|---|---|
| `job.list` / `job.get` | R | Running and finished jobs |
| `job.wait` | R | Block until a job finishes or a timeout passes |
| `job.cancel` | W | Stop a job. Finished parts are kept (R-3) |

## Browser

| Tool | | Purpose |
|---|---|---|
| `browser.open` / `browser.close` | W | Show or hide the browser, choose a profile (B-1) |
| `browser.newSession` | W | Fresh page in the same profile (B-3) |
| `browser.navigate` | W | Go to a URL, back or forward |
| `browser.read` | R | The page as a structured tree with element references |
| `browser.click` / `browser.type` / `browser.select` | W | Act on an element reference (B-2); `trusted` clicks and `keys` typing act like a person |
| `browser.key` | W | Press Return, Escape or Tab in the page |
| `browser.attachFiles` | W | Give files to an upload field, through the chooser a button opens, or dropped on a drop area |
| `browser.waitFor` | R | Wait for text, an element or a download |
| `browser.capture` | R | Image of the page or of one element |
| `browser.generateImage` | job | One image on Google AI Studio (Nano Banana Pro, 4K by default): fresh session, run settings, input images, prompt typed like a person, retries on site errors, full-size image saved into the project or a folder |
| `browser.html` | R | Markup of an element, for pages `browser.read` does not explain |
| `browser.listResults` | R | Generated images found on the page and finished downloads |
| `browser.saveResult` | W | Save a download or a page image into the project's images folder or a composition's assets (B-5) |

## Reference downloads

Posts from YouTube, Pinterest, Instagram and X (and other sites yt-dlp
knows), fetched by link as references (D-1 to D-5). A download is a folder
named `<platform>-<post key>` (`youtube-dQw4w9WgXcQ`, `x-1777`,
`pinterest-42`) in the open project's `downloads/` folder, or in the
editor's cache (`downloads/` next to the settings file) when no project is
open; `downloader.projectFolder` and `downloader.cacheFolder` move them. Each
holds the files, `info.json` (metadata, files, source, warnings) and
`inspect/` for sheets and frames. Downloading the same post again (say its
sound after its video) adds to the same folder.

| Tool | | Purpose |
|---|---|---|
| `social.download` | job | `url`; `what` video, audio, images or all (default: the video, and the pictures of items without video); `quality` a name from `downloader.qualities` (best, 1080, 720, 480; default 1080, H.264 and AAC in MP4 first) or a yt-dlp format; `subtitles`; `import` (also into the media pool, returns media ids); `playlistLimit`. Returns the download id at once; `job.wait` gives files (kind, bytes, duration, size), paths and metadata (title, uploader, upload date, description, duration, view, like and comment counts, original URL, platform, formats, subtitle languages, carousel items) |
| `social.info` | R | Metadata only, no download, with the formats offered and the subtitle and automatic caption languages; a photo post lists its pictures; `needsLogin` when the site showed a sign-in wall |
| `social.inspect` | R | `id`: a contact sheet of evenly spaced frames, or of the pictures (returned as an image and saved), single frames saved at `times` or `frames` evenly spaced, the subtitle text, the loudness (integrated and short-term LUFS, peak) |
| `social.list` | R | Downloads in the project and the cache, with files, bytes, media ids in the pool and the number of clips using them |
| `social.cleanup` | M | `ids` or `all`: move downloads with their sidecar, sheets and frames to the Trash; refused for a download that clips use unless `force`; unused pool entries are removed first; reports what was trashed and the bytes freed |

- Media comes from yt-dlp. A post without video (an Instagram photo or
  carousel item, a Pinterest image pin, an X photo) gives its pictures from
  yt-dlp's metadata at full size, else from the page's `og:image` and
  `og:video` tags.
- An item behind a sign-in wall fails with code `locked` and says so. With
  `downloader.cookiesFromBrowser` set (for example `safari`), yt-dlp uses
  that browser's sign-in; it is off by default.

## App window (the app only)

| Tool | | Purpose |
|---|---|---|
| `ui.state` | R | What the window shows: project, selection, playhead, zoom, side panel, what the panels act on |
| `ui.select` | M | Select clips on the timeline, as a click would |
| `ui.zoom` | M | Fit, zoom in or out, or set pixels per second |
| `ui.copy` | M | Copy the selected clips for a paste at the playhead (Cmd+C; Cmd+V runs `clip.copyTo`) |
| `ui.deleteRange` | W | Delete the range marked on the ruler (⌥-drag), or the given one, from every unlocked track |
| `ui.key` | M | Press a shortcut as the owner would; it acts on the selection and playhead |
| `ui.selfTest` | M | Work the window like a person on a scratch project and report each check (92; 97 with `downloadURL`, which also tests Download from Link with a real post): clicks, drags, trims, snapping, scrubbing, every shortcut, the colour, effect and transform sliders, the Accent, Clip, Media and Words panels, track header buttons, markers, right-click menus, placing imported files, a marked range, menus, Settings, History, transport buttons, keyframe easing, colour presets, agent notes, the shortcuts list, Page Up/Down and Return jumps, hour-long timelines |

## Parity check

A test in the repository walks the command registry and fails if a command
has no MCP tool, or if a menu item or key binding calls anything that is not a
registered command (N-2).
