#!/bin/bash
# Generates synthetic source files for the phase 0 probes (docs/phase0.md).
# Output goes to local/probe-media/, which git ignores.
#
# sync_4k60.mov: 3840x2160, 60 fps, HEVC Main 10, Rec.709, about 50 Mb/s
#   (close to camera 4K 60 footage), 48 kHz AAC stereo. For the first three
#   frames of every second the picture is white and a 1 kHz beep plays for
#   exactly those frames, so picture-to-sound offset can be measured after any edit.
# tone_220.wav: a 220 Hz tone with harmonics, for pitch measurement.
set -euo pipefail
cd "$(dirname "$0")/.."
out=local/probe-media
mkdir -p "$out"
seconds="${1:-60}"

if [[ ! -f "$out/sync_4k60.mov" ]]; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=s=3840x2160:r=60:d=${seconds},drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(n\,60)\,3)'" \
    -f lavfi -i "aevalsrc='if(lt(mod(t\,1)\,3/60)\,0.5*sin(2*PI*1000*t)\,0)|if(lt(mod(t\,1)\,3/60)\,0.5*sin(2*PI*1000*t)\,0)':s=48000:d=${seconds}" \
    -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -b:v 50M -tag:v hvc1 \
    -bsf:v hevc_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1 \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac -b:a 256k \
    "$out/sync_4k60.mov"
fi

if [[ ! -f "$out/tone_220.wav" ]]; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc='0.4*sin(2*PI*220*t)+0.2*sin(2*PI*440*t)+0.1*sin(2*PI*660*t)':s=48000:d=10" \
    -c:a pcm_s16le "$out/tone_220.wav"
fi

# Overlays with transparency, as HyperFrames renders them: a white disc that
# moves across a clear background, 1080x1920, 60 fps, 5 s.
alpha_src="color=c=black@0.0:s=1080x1920:r=60:d=5,format=rgba,geq=r='255':g='255':b='255':a='if(lt(hypot(X-(200+T*130),Y-960),180),255,0)'"
if [[ ! -f "$out/alpha_hevc.mov" ]]; then
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$alpha_src" \
    -c:v hevc_videotoolbox -alpha_quality 0.9 -tag:v hvc1 -pix_fmt bgra "$out/alpha_hevc.mov"
fi
if [[ ! -f "$out/alpha_prores.mov" ]]; then
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$alpha_src" \
    -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le "$out/alpha_prores.mov"
fi

ls -l "$out"

# Tests/MediaEngineTests/Fixtures/opengop_numbered.mov (checked in, 8 s,
# 320x240, 30 fps): open-GOP HEVC whose frame N has luma 20 + (N mod 100) * 2,
# so a test can tell exactly which frame came out. Regenerate with:
#   ffmpeg -f lavfi -i "nullsrc=s=320x240:r=30:d=8,format=yuv420p,geq=lum='20+mod(N\,100)*2':cb=128:cr=128" \
#     -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p \
#     -x265-params "keyint=32:min-keyint=32:open-gop=1:bframes=3:b-pyramid=1:scenecut=0" opengop_numbered.mov
