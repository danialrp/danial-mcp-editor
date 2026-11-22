# Phase 0 results

Measurements behind the playback and export design. Design is in
[architecture.md](architecture.md); the tests are listed in its section 15.

The numbers compare designs with each other; they are not a specification.

## How to repeat

```bash
scripts/make-probe-media.sh
```

```bash
scripts/swift.sh build -c release --product dme-probe
```

```bash
.build/release/dme-probe playback local/probe-media/sync_4k60.mov --cuts 500 --speed 1.22
```

The synthetic source is 3840x2160, 60 fps, HEVC Main 10 at 50 Mb/s. Its first
three frames of every second are white and carry a 1 kHz beep, so picture to
sound offset can be measured after any edit. The other commands are listed by
running `dme-probe` with no arguments.

## Test 1: playback with many cuts

Custom Metal compositor, 10-bit YUV input, speed 1.22 with pitch kept,
25 seconds of playback, frames pulled at 240 Hz the way a display link does.

| Source | Cuts | Render size | Frames arrived / expected | Late frames | Memory |
|---|---|---|---|---|---|
| 4K 60 synthetic | 0 | 3840x2160 | 1500 / 1501 | 3 | 1101 MB |
| 4K 60 synthetic | 500 in 60 s | 3840x2160 | 1502 / 1501 | 1 | 1039 MB |
| 4K 60 synthetic | 0 | 1920x1080 | 1478 / 1501 | 41 | 278 MB |
| 4K 60 synthetic | 500 in 60 s | 1920x1080 | 1481 / 1501 | 44 | 283 MB |
| 1080p 30 test recording, 20 min | 500 | 1920x1080 | 751 / 751 | 3 | 195 MB |

- Cuts do not cost frames. 500 cuts in one minute, far denser than any real
  edit, play as cleanly as no cuts.
- Every run has one slow frame at the start (100 to 240 ms) while playback
  starts. Later late frames are single 25 to 60 ms stalls.
- Rendering a frame takes 1 to 4 ms at the median.
- Full-size 4K preview needs about 1.1 GB, because every frame is 4K RGBA half
  float. Rendering the preview at a smaller size cuts that to under 300 MB, but
  in this run it produced more late frames, not fewer. The cause is not known
  yet; a likely suspect is the GPU dropping to a lower clock under light load.
- No sync mark was off by a frame or more during playback.
- **Found and fixed:** a recorded file starts its first picture 50 ms
  after time zero. The compositor received a request with no source frame,
  returned an error, and playback stopped for the whole file. A time with no
  picture now renders black. The editor's render graph must do the same.

**Decision:** the AVFoundation composition path with a custom Metal compositor
is kept. Preview size and memory are settled in phase 2.

## Test 2: export in segments, joined without re-encoding

Segments of 2 s (120 frames), each rendered and HEVC-encoded to its own file,
audio rendered in one pass, then all joined with a passthrough export.

- Frame count exact in every run (1978 of 1978 after 500 cuts), no decode
  errors, colour tags correct.
- Speed: 4K 60 export runs at 0.8x real time, 2K at 1.5x to 1.7x. Rendering
  two or three segments at once barely helps, so the hardware encoder is the
  limit.

Picture to sound offset (beep minus first white frame; the flash can only
start on a frame, so up to -16.7 ms is the expected quantisation):

| Cuts | Speed | Offset range | Median |
|---|---|---|---|
| 0 | 1 | 0.0 to 0.0 ms | 0.0 ms |
| 500 | 1 | 0.0 to 0.0 ms | 0.0 ms |
| 0 | 1.22 | -19.3 to +7.0 ms | -5.7 ms |
| 500 | 1.22 | -21.1 to +4.5 ms | -7.6 ms |

- Cuts add no offset at all.
- The speed change spreads the offset by a few milliseconds beyond frame
  quantisation, never more than about half a frame.

**Decision:** segment export is kept as designed. The 4K export target (faster
than real time) is not met in these measurements; 2K, the Reels delivery size, is.

## Test 3: HDR (HLG) source through the pipeline

Source: an HLG test file (1440x2560, 60 fps, HEVC Main 10, HLG). Exported
through the compositor and segment export, then both read back through the
same compositor and compared on every 30th frame.

- Colour tags kept: BT.2020, HLG, 10-bit. No decode errors.
- Mean difference: 3.7 ten-bit code values, close to what one more HEVC
  generation at the same bitrate costs.
- Mean signed difference: +1.3 code values, a small, steady shift. It is
  likely a rounding difference between the compositor's YUV conversion and the
  encoder's. It is fixed when the colour engine is built in phase 4.
- Not covered: how the player window shows HDR on screen compared with other
  players. That needs the real player view in phase 2.

## Test 4: speed 1.22 with pitch kept

220 Hz tone, sped up 1.22 times:

| Algorithm | Pitch | Length |
|---|---|---|
| spectral | 220.2 Hz | 8.210 s (8.197 expected) |
| time domain | 220.2 Hz | 8.203 s |
| varispeed (pitch not kept) | 268.2 Hz | 8.197 s |

Both pitch-keeping algorithms hold the pitch exactly. Thirty-second voice
samples from a test recording, at 1.22 with each algorithm and the original,
are in `local/probe-results/` (not in the repository) for listening.

**Open:** which algorithm sounds closest to Edits is a listening decision for
the owner.

## Test 5: HyperFrames renderer, Chrome or WebKit (phase 7)

A 4 s, 1080x1920, 60 fps test composition (right-to-left text with a
shadow, a gradient card, a moving circle, GSAP timeline) rendered by the
HyperFrames command line (headless Chrome) and frame by frame in an
in-process `WKWebView` (seeking the GSAP timeline, transparent snapshots).

| | HyperFrames (Chrome) | WebKit |
|---|---|---|
| Time | 15.6 s for 240 frames, ProRes 4444 written | 16.1 s for 240 frames, 67 ms each, not encoded |
| Alpha | yes | yes |
| Same frame | reference | 0.2% of pixels differ by more than 32 of 255, mean 0.3 |

The differences sit on the card, the circle and the text edges: antialiasing
and text shaping differ between the two engines.

**Decision:** the HyperFrames command line (Chrome). Requirement H-5 asks for
identical output, WebKit is not faster, and HyperFrames' own runtime (clip
timing, sub-compositions, shader transitions, motion blur) exists only in its
Chrome pipeline.
