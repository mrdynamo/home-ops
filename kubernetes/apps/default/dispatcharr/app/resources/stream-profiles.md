# Dispatcharr Stream & Output Profiles — NVENC vs Intel QSV

Notes for running Dispatcharr's ffmpeg profiles on Intel Quick Sync (QSV)
instead of NVIDIA NVENC, since the Dispatcharr host uses an Intel iGPU.

All profiles below were last tested on 2026-11-17 inside the dispatcharr pod
(Dispatcharr 0.34.0, bundled FFmpeg 9.0.2, Intel iHD 26.3.5, i5-11500 / Rocket
Lake UHD 750).

> **Every `h264_qsv` profile needs `-low_power 1`** (Dispatcharr ≥ 0.34.0), in
> stream profiles and output profiles alike. Without it the encoder won't open
> and logs `Selected ratecontrol mode is unsupported` /
> `Current frame rate is unsupported` / `Current pixel format is unsupported`.
> See [Dispatcharr 0.34.0 breaking changes](#dispatcharr-0340-breaking-changes).

## Stream profiles vs output profiles

Dispatcharr has two separate kinds of ffmpeg profile. They sit at different
points in the pipeline and are assigned in different places:

```text
provider ──► stream profile ──► channel TS buffer ──┬─► client (no output profile)
             (1 per channel)    (Redis, shared)     ├─► output profile A ──► Emby users
                                                    └─► output profile B ──► …
                                                        (1 per channel × output profile)
```

| | Stream profile | Output profile |
| --- | --- | --- |
| Scope | Global, at the channel level. Settings → Stream Settings → **Default Stream Profile**, overridden per channel (channel edit / bulk edit → Stream Profile) or for channels created by an M3U group's auto channel sync. | Per user/device. A user's **Output Profile Override** (Settings → Users; cleared = no transcoding — here: the Emby users), the **Output Profile** option on a generated M3U URL (`?output_profile=<id>`) or HDHR URL (`/output_profile/<id>/`), or the **HDHR Default Output Profile**, **Web Player Output Profile** and **DVR Output Profile** settings. |
| Input | The provider stream. ffmpeg fetches it itself: `-user_agent {userAgent} -i {streamUrl}` | The stream profile's output, written to ffmpeg's stdin: `-i pipe:0` (required) |
| Placeholders | `{streamUrl}`, `{userAgent}`, `{channelId}`, `{channelName}`, `{tvgId}` | None. Input is always `pipe:0`. |
| Processes | For ffmpeg/VLC/streamlink/custom profiles: one per active channel, with every viewer sharing that one backend stream. The built-in Proxy profile runs no transcoder, and Redirect hands the provider URL straight to the client. | One per active (channel, output profile) pair. Every client requesting that pair shares its output buffer. |
| Output | `-f mpegts pipe:1` → the channel buffer | Must be MPEG-TS: `-f mpegts pipe:1` → that profile's own buffer. The container sent to the client (MPEG-TS / fMP4 / HLS) is the separate **Output Format** setting. |

What this means in practice:

- **A stream profile changes the channel for everyone.** Keep it cheap, because
  every viewer and every output profile is fed from its output.
- **An output profile adapts the channel for one client type.** Here it sets a
  fixed 8 Mbps H.264 + AAC 384k for Emby. Other users keep receiving the stream
  profile's output untouched.
- **They stack.** If a channel's stream profile transcodes video and an Emby
  user also has a transcoding output profile, the video is encoded twice. That
  costs two iGPU encode sessions and quality from the second encode. The
  current setup avoids this: the
  [channel stream profile](#channel-stream-profile-in-use) copies video, so the
  Emby output profile does the only video encode.
- **Redirect channels get no output profile.** Redirect bypasses Dispatcharr's
  proxy, so there is no channel buffer for an output profile to read. (Inferred
  from the docs and code; not tested.)

### Sources

Checked on 2026-11-17 against the official docs and the v0.34.0 code:

- Official docs:
  [System → Stream Profiles / Output Profiles](https://dispatcharr.github.io/Dispatcharr-Docs/system/#stream-profiles)
  (`docs/en/system.md` in `Dispatcharr/Dispatcharr-Docs`). That page covers
  the "one transcode per active (channel, profile) pair, shared buffer" model,
  the `pipe:0`/`pipe:1`/MPEG-TS requirement, the user Output Profile Override,
  and the HDHR / Web Player / DVR output profile settings.
- Official docs: [Channels](https://dispatcharr.github.io/Dispatcharr-Docs/channels/)
  (per-channel stream profile, plus the Output Profile option on M3U/HDHR URLs)
  and [M3U & EPG Manager](https://dispatcharr.github.io/Dispatcharr-Docs/m3u-epg-manager/)
  (stream profile for auto-created channels).
- Code (`Dispatcharr/Dispatcharr@v0.34.0`):
  - `core/models.py`: `StreamProfile.build_command` substitutes the
    placeholders; `OutputProfile.build_command` does no substitution. Both
    split the parameters with `shlex` and run without a shell.
  - `apps/proxy/live_proxy/output/profile/manager.py`: an output profile reads
    the channel's Redis TS buffer, feeds it to stdin, and restarts ffmpeg at
    stream boundaries.
  - `apps/hdhr/urls.py`, `apps/output/views.py`: the URL forms.
- The Channels page labels the URL option "override the default stream
  profile". That wording is loose. The output profile *adds* a transcode on top
  of the channel's stream profile; it doesn't replace it (System page and code).
- The official hardware-acceleration page's **Intel QSV** example
  (`-hwaccel qsv … -c:v h264_qsv …`) has no `-low_power 1`, so it fails on
  0.34.0 with this iGPU. See
  [Dispatcharr 0.34.0 breaking changes](#dispatcharr-0340-breaking-changes).

## Stream profiles (channel level)

### Channel stream profile (in use)

Used for all channels. Video is copied untouched, and only the audio is
re-encoded (to AC3):

```text
-fflags +discardcorrupt+genpts -user_agent {userAgent} -i {streamUrl} -g 60 -keyint_min 60 -sc_threshold 0 -force_key_frames "expr:gte(t,n_forced*0)" -map 0 -c:v copy -c:a ac3 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

- **`-g 60 -keyint_min 60 -sc_threshold 0 -force_key_frames …` are no-ops.**
  They're encoder options, and `-c:v copy` doesn't encode. In testing, the
  video with and without them was byte-identical. They are also a trap:
  `expr:gte(t,n_forced*0)` is always true, so if this profile ever switched
  to encoding video, every frame would become a keyframe. Cleaned version
  (same output):

  ```text
  -fflags +discardcorrupt+genpts -user_agent {userAgent} -i {streamUrl} -map 0 -c:v copy -c:a ac3 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
  ```

- **Video reaches output profiles exactly as the provider sends it:** source
  codec (H.264 / HEVC / MPEG-2), interlacing and frame rate. Deinterlacing,
  frame-rate capping and decoding therefore all fall to the output profile.
- **Audio is converted twice for Emby users** (source → AC3 here, AC3 → AAC
  384k in the output profile). It's cheap, but `-c:a copy` here would leave the
  output profile as the only audio encode, at the cost of other clients
  receiving the source audio codec.
- No iGPU use, so no `-low_power` concerns.

### Live stream QSV (full GPU, alternative — not in use)

A transcoding stream profile, for a channel that needs normalising for every
viewer. Decode, deinterlace and encode all stay on the iGPU, so the CPU only
handles demux and audio. It ran at about 220 fps for 1080p in testing. Don't
pair it with a transcoding output profile ([they stack](#stream-profiles-vs-output-profiles)).

```text
-hwaccel qsv -qsv_device /dev/dri/renderD128 -hwaccel_output_format qsv -user_agent {userAgent} -fflags +genpts+discardcorrupt -i {streamUrl} -vf format=nv12|p010|qsv,hwupload=extra_hw_frames=64,vpp_qsv=deinterlace=2:format=nv12 -c:v h264_qsv -low_power 1 -b:v 4M -maxrate 4M -bufsize 8M -g 60 -c:a aac -f mpegts pipe:1
```

- `-user_agent` is an input option, so it must come before `-i {streamUrl}`.
- `format=nv12|p010|qsv,hwupload=…` lets frames that are already on the GPU
  pass straight through, and uploads them if ffmpeg had to fall back to
  software decode. Without it, a source the iGPU can't decode silently
  produces audio-only output. See
  [Hardware decode fallback](#hardware-decode-fallback-behaviour).
- `vpp_qsv=deinterlace=2:format=nv12` and `-g 60` are explained in the
  [output profile notes](#notes-on-the-qsv-output-profiles). `format=nv12` is
  required for 10-bit sources.
- No `-fps_mode cfr`. On live feeds it duplicates or drops frames whenever the
  source timestamps jump.

### HDR (HLG) sources — Sky Sports F1 UHD

The Sky Sports F1 4K streams are **HEVC Main 10, 3840×2160, 50 fps, HLG**
(`color_transfer=arib-std-b67`, BT.2020, no HDR10 mastering metadata), at
about 23 Mbps. It's the only HDR channel. Checked 2026-11-17 from a 20 s capture
through Dispatcharr's own proxy.

The H.264 output profiles convert it to 8-bit (`vpp_qsv=…:format=nv12`) but
can't tone map it, so Emby gets a flat, washed-out SDR picture. Tone mapping
can't go in the output profile, because output profiles apply to every channel
a user watches. It has to be a stream profile on this channel only.

What was tested on the real feed (output 1080p50 H.264, CPU measured as a share
of one core at realtime):

| Method | Picture | Speed | CPU |
| --- | --- | --- | --- |
| No tone mapping (`vpp_qsv=format=nv12`) | Flat, greyish, muted colour | 3.3× | ~0 |
| `vpp_qsv` `tonemap=1` | Identical to no tone mapping: it only acts on HDR10 mastering metadata, which HLG doesn't have | 3.3× | ~0 |
| `vpp_qsv` / `scale_vaapi` `out_color_*=bt709` | Byte-identical to each other and barely different from no tone mapping: no BT.2020 → BT.709 gamut mapping | 2.7–2.8× | ~0.2 core |
| `vpp_qsv` `saturation`/`contrast` | Ignored (identical output for different values) | 2.7× | ~0.2 core |
| `tonemap_vaapi` | Fails (`Invalid argument`): HDR10 input only | — | — |
| `tonemap_opencl` | Unavailable: no OpenCL runtime in the image | — | — |
| CPU `zscale` linear → `tonemap=hable`/`mobius` → BT.709 | Good colour and contrast; hable is darker | 1.0× | ~6 cores |
| **CPU `zscale` direct HLG → BT.709** | **Best: bright, natural, like a native SDR broadcast** | **1.65×** | **~3.4 cores** |

Tone-mapping stream profile (tested via HTTP with `-user_agent`, exactly as
Dispatcharr runs it). The iGPU decodes and scales to 1080p, the CPU converts
HLG → BT.709, and the iGPU encodes:

```text
-hwaccel qsv -qsv_device /dev/dri/renderD128 -hwaccel_output_format qsv -user_agent {userAgent} -fflags +genpts+discardcorrupt -i {streamUrl} -map 0:v:0 -map 0:a? -vf vpp_qsv=w=1920:h=1080:format=p010,hwdownload,format=p010le,zscale=tin=arib-std-b67:pin=bt2020:min=bt2020nc:t=bt709:p=bt709:m=bt709:r=tv:npl=203,format=nv12,hwupload=extra_hw_frames=64 -c:v h264_qsv -low_power 1 -b:v 15M -maxrate 15M -bufsize 30M -g 100 -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a ac3 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

- Output: 1080p50 H.264 tagged BT.709, at 15 Mbps so the Emby output profile's
  second encode loses little. The Emby uncapped output profile chained on this
  ran at 4.1× realtime and ~0.2 core.
- Every viewer of the channel gets 1080p SDR, including clients that could
  play 4K HDR.
- `zscale`'s dithering setting made no measurable CPU difference.
- **Failover hazard:** the `tin=/pin=/min=` options force HLG input. The
  channel's 26 streams are 3 × 4K HLG (plus F1-TV 1080p 10-bit, HDR status
  unknown) and 22 × 8-bit SDR. On an SDR fallback stream, forced HLG mangles the
  picture (PSNR 14.5 dB against the source). Dropping the forced options
  produces byte-identical output on the HLG feed, but fails on SDR streams with
  `no path between colorspaces`, because they leave primaries and transfer
  unset. A static ffmpeg filter graph can't branch on the input, so this profile
  only belongs on a channel whose streams are all HLG.

## Output profiles (per user/device — Emby)

Each set has 3 variants:

1. Uncapped FPS (keeps the source framerate)
2. Capped at 30 fps
3. Capped at 60 fps

### Intel QSV output profiles — hardware decode (recommended)

Decode, deinterlace, frame-rate conversion and encode all run on the iGPU. The
CPU only demuxes and encodes the audio.

**Uncapped FPS:**

```text
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -hwaccel qsv -qsv_device /dev/dri/renderD128 -hwaccel_output_format qsv -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf format=nv12|p010|qsv,hwupload=extra_hw_frames=64,vpp_qsv=deinterlace=2:format=nv12 -c:v h264_qsv -low_power 1 -preset medium -profile:v high -look_ahead 0 -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**30 fps cap:**

```text
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -hwaccel qsv -qsv_device /dev/dri/renderD128 -hwaccel_output_format qsv -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf format=nv12|p010|qsv,hwupload=extra_hw_frames=64,vpp_qsv=deinterlace=2:format=nv12:framerate=30000/1001 -fps_mode cfr -c:v h264_qsv -low_power 1 -preset medium -profile:v high -look_ahead 0 -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**60 fps cap:**

```text
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -hwaccel qsv -qsv_device /dev/dri/renderD128 -hwaccel_output_format qsv -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf format=nv12|p010|qsv,hwupload=extra_hw_frames=64,vpp_qsv=deinterlace=2:format=nv12:framerate=60000/1001 -fps_mode cfr -c:v h264_qsv -low_power 1 -preset medium -profile:v high -look_ahead 0 -b:v 8M -maxrate 8M -bufsize 16M -g 120 -keyint_min 120 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

### Intel QSV output profiles — CPU decode (fallback)

The previous versions: software decode from stdin, then `hwupload` to the iGPU
for encoding only. They don't deinterlace. Use them only for a channel whose
feed the iGPU can't decode at all, i.e. one that fails with
`Error querying IO surface` (see
[Hardware decode fallback](#hardware-decode-fallback-behaviour)).

**Uncapped FPS:**

```text
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf format=nv12,hwupload=extra_hw_frames=64 -c:v h264_qsv -low_power 1 -preset medium -profile:v high -look_ahead 0 -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**30 fps cap:**

```text
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf fps=30000/1001,format=nv12,hwupload=extra_hw_frames=64 -fps_mode cfr -c:v h264_qsv -low_power 1 -preset medium -profile:v high -look_ahead 0 -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**60 fps cap:**

```text
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf fps=60000/1001,format=nv12,hwupload=extra_hw_frames=64 -fps_mode cfr -c:v h264_qsv -low_power 1 -preset medium -profile:v high -look_ahead 0 -b:v 8M -maxrate 8M -bufsize 16M -g 120 -keyint_min 120 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

### Original NVENC output profiles

These still parse under FFmpeg 9 and need no changes. The bundled FFmpeg targets
NVENC API 13.0, so an NVIDIA host would need driver 570 or newer.

**Uncapped FPS:**

```text
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -c:v h264_nvenc -preset p4 -profile:v high -pix_fmt yuv420p -rc cbr -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -sc_threshold 0 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**30 fps cap:**

```text
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf fps=30000/1001 -fps_mode cfr -c:v h264_nvenc -preset p4 -profile:v high -pix_fmt yuv420p -rc cbr -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -sc_threshold 0 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**60 fps cap:**

```text
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf fps=60000/1001 -fps_mode cfr -c:v h264_nvenc -preset p4 -profile:v high -pix_fmt yuv420p -rc cbr -b:v 8M -maxrate 8M -bufsize 16M -g 120 -keyint_min 120 -sc_threshold 0 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

### Notes on the QSV output profiles

Changes from NVENC (both QSV sets):

- `-c:v h264_nvenc` → `-c:v h264_qsv -low_power 1`. `-low_power 1` selects the
  VDENC fixed-function encoder, the only H.264 encode path the 0.34.0+ driver
  offers.
- `-preset p4` (NVENC's p1–p7 scale) → `-preset medium` (QSV's veryfast…veryslow
  scale).
- Dropped `-rc cbr` and `-sc_threshold 0`. h264_qsv has no `-rc` option; it
  chooses the rate-control mode from the bitrate options. Equal `-b:v` and
  `-maxrate` makes it pick CBR: the encoder logs
  `Using the constant bitrate (CBR) ratecontrol method`. `-look_ahead 0` keeps
  lookahead off.
- Dropped `-pix_fmt yuv420p`. The hardware chain works in NV12 (8-bit 4:2:0),
  and the output is H.264 High.

Hardware-decode set:

- **Why decode on the iGPU:** the channel stream profile copies video, so the
  output profile must decode the source to re-encode it. Hardware decode moves
  that work off the CPU; it doesn't add any. Measured per active channel ×
  profile, as a share of one CPU core at realtime:

  | Source | CPU decode (fallback set) | Hardware decode (recommended set) |
  | --- | --- | --- |
  | 1080p60 H.264 → 30 fps cap | ~55% | ~12% |
  | 1080i H.264 → 30 fps cap | ~37% | ~10% |
  | 1080i MPEG-2 → 30 fps cap | — | ~10% |
  | 1080p60 H.264 → 60 fps cap / uncapped | — | ~17% |

  4K sources are limited by the iGPU, not the CPU. See
  [4K / 10-bit sources](#4k--10-bit-sources).

- `-hwaccel qsv -hwaccel_output_format qsv` decodes with the h264_qsv,
  hevc_qsv or mpeg2_qsv decoders and keeps frames in GPU memory. `-qsv_device`
  picks the render node, so `-init_hw_device`/`-filter_hw_device` aren't needed.
- `format=nv12|p010|qsv,hwupload=extra_hw_frames=64` keeps zero-copy on the
  hardware path: frames already on the GPU pass straight through, and the
  measured CPU cost was identical with and without it. If ffmpeg falls back to
  software decode, it uploads the frames (`p010` lets a 10-bit software decode
  upload without a CPU conversion). Don't remove it: without it, `vpp_qsv` drops
  every software-decoded frame and the output is audio-only, with exit code 0.
- `vpp_qsv=…:format=nv12` converts every source to 8-bit 4:2:0 on the GPU.
  **Required for 10-bit sources** (e.g. HEVC Main 10, common on 4K/UHD
  feeds): the hevc_qsv decoder outputs 10-bit P010 frames, and h264_qsv only
  encodes 8-bit. Without it, the encoder fails with
  `Current pixel format is unsupported`. It does nothing to sources that are
  already 8-bit.
- `vpp_qsv=deinterlace=2` uses QSV's advanced deinterlacer. It outputs one
  frame per interlaced frame (1080i29.97 → 29.97p). Without it, interlaced
  feeds reach Emby with visible combing, labelled as progressive. Progressive
  sources pass straight through unchanged.
- `vpp_qsv=…:framerate=30000/1001` (or `60000/1001`) replaces the CPU `fps`
  filter, so frame-rate conversion stays on the GPU. `-fps_mode cfr` stays, to
  keep the capped output constant-rate.
- `-g 60` / `-g 120` give a keyframe every 2 s at 29.97 / 59.94 fps.
- Mid-stream source changes (for example a failover to a stream with a different
  codec or resolution) are handled by Dispatcharr. Its output-profile manager
  restarts the ffmpeg process at stream boundaries, so the hardware decoder
  never has to cope with a changing input.

CPU-decode set:

- `-init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw` (global
  options) creates the QSV device that `hwupload` uses. The text after `hw:` is
  really QSV's *implementation* selector, not a device path. An unrecognised
  value falls back to auto-selection, which finds the only iGPU, so this works
  on this hardware. The strictly correct form is
  `-init_hw_device qsv=hw:hw,child_device=/dev/dri/renderD128`.
- `format=nv12,hwupload=extra_hw_frames=64` converts software-decoded frames to
  NV12 and moves them onto a QSV surface for encoding. The capped variants run
  the CPU `fps` filter first.

### Hardware decode fallback behaviour

How the hardware-decode chain (`-hwaccel qsv … format=nv12|qsv,hwupload,vpp_qsv`)
handles different sources:

| Source | What happens | Result |
| --- | --- | --- |
| H.264 8-bit 4:2:0, HEVC (8- or 10-bit), MPEG-2 (progressive or interlaced) | Hardware decode; 10-bit is converted to 8-bit by `vpp_qsv=…:format=nv12` | Works, ~10–17% of a core at 1080p |
| Codec with no QSV decoder (e.g. MPEG-4 Part 2) | ffmpeg uses its software decoder; `hwupload` uploads the frames | Works, ~30% of a core |
| A codec QSV has a decoder for, but not this variant (e.g. 4:2:2 or 10-bit "High 10" H.264) | h264_qsv is selected and refuses the stream: `Error querying IO surface: unsupported` | Fails (no automatic fallback). Use the CPU-decode set for that channel's viewers. |

### 4K / 10-bit sources

Tested with a synthetic 3840×2160 50 fps HEVC Main 10 source, the same format
class as the Sky Sports F1 "RAW HEVC" 4K feed:

| Output profile | Result | Speed (one stream) |
| --- | --- | --- |
| Uncapped, without `format=nv12` | `Current pixel format is unsupported`, no output | — |
| 30 fps cap | 4K 29.97p H.264 | 2.1× realtime |
| 60 fps cap | 4K 59.94p H.264 (50 → 59.94 fps upsampled) | 1.16× realtime |
| Uncapped | 4K 50p H.264 | 1.37× realtime |
| Uncapped + 1080p cap (below) | 1080p50 H.264 | 3.2× realtime |

- **The iGPU is close to its limit at 4K.** Decoding 4K HEVC and encoding 4K
  H.264 runs at only 1.2–1.4× realtime for one stream. Two concurrent 4K
  transcodes, or one plus other iGPU work, will fall behind and buffer.
- **8 Mbps is too little for 4K H.264**, which typically needs 20–25 Mbps
  for sports. At 8 Mbps you're paying 4K's cost for worse quality than
  1080p.
- **HDR:** if a feed is HDR (HLG/PQ), converting it to 8-bit SDR H.264 without
  tone-mapping gives flat, washed-out colour. Check with
  `ffprobe -show_entries stream=color_transfer,color_primaries`. HDR shows as
  `arib-std-b67` (HLG) or `smpte2084` (PQ). The Sky F1 4K feed is HLG. See
  [HDR (HLG) sources](#hdr-hlg-sources--sky-sports-f1-uhd) for what was tested.

Optional **1080p cap**: add `w`/`h` to `vpp_qsv` so 4K is scaled down on the
GPU. `min(iw\,1920)` means 1080p and smaller sources are never upscaled
(tested: 720p stays 720p). Dispatcharr splits parameters with `shlex`, which
strips an unquoted backslash and lets ffmpeg split the filter at the comma.
So **the `-vf` value must be in single quotes**:

```text
-vf 'format=nv12|p010|qsv,hwupload=extra_hw_frames=64,vpp_qsv=deinterlace=2:format=nv12:w=min(iw\,1920):h=-1'
```

For the capped variants, append `:framerate=30000/1001` / `:framerate=60000/1001`
inside the quotes.

### Troubleshooting: client loads forever, channel shows active

The channel shows active because the stream profile is running fine. If an
output profile's ffmpeg fails, Dispatcharr doesn't pass the error on to the
client: the client stays connected with 0 bytes sent until it gives up, and
the "Client Disconnected" notification shows `Data Sent: 0 MB`. The output
profile's ffmpeg stderr is in the app container log, tagged
`[Profile:<output profile id>:<channel uuid prefix>]`:

```sh
kubectl -n default logs deploy/dispatcharr -c app --since=10m | grep '\[Profile:'
```

Look for `Conversion failed!` and the error just before it:

| Error | Cause / fix |
| --- | --- |
| `Current pixel format is unsupported` | 10-bit source without `vpp_qsv=…:format=nv12`, or `-low_power 1` missing |
| `Selected ratecontrol mode is unsupported` (plus frame rate / resolution) | `-low_power 1` missing |
| `Error querying IO surface: unsupported` | The iGPU can't decode this source (4:2:2 or 10-bit H.264). Use the CPU-decode set. |
| `Could not find codec parameters … unspecified size` | `-probesize 512K -analyzeduration 1M` is too small to identify the stream when joining mid-GOP (seen with the 4K HEVC feed). Not fatal there, since the decoder still opened. If a channel fails on it, raise both, at the cost of slower channel start. |

## Dispatcharr 0.34.0 breaking changes

0.34.0 (Renovate PR #3983, 2026-11-17) swapped the image's base from
`lscr.io/linuxserver/ffmpeg:8.1.2-cli` to Dispatcharr's own
`ghcr.io/dispatcharr/ffmpeg` (built from `github.com/Dispatcharr/FFmpeg`). That
swap broke QSV stream and output profiles that had worked on 0.33.0:

1. **FFmpeg 8.1.2 → 9.0.2 removed `-vsync`.** FFmpeg 8 still accepted it as a
   deprecated alias. FFmpeg 9 fails with `Unrecognized option 'vsync'` before
   it touches the GPU. Use `-fps_mode` instead. The Emby output profiles
   already did; the old live stream profile used `-vsync cfr`.
2. **The Intel media driver is now built with `-DENABLE_NONFREE_KERNELS=OFF`**
   (`scripts/build-intel-media.sh` in that repo). linuxserver built iHD with
   cmake defaults, which include the non-free kernels.
   - Intel GPUs have two H.264 encode paths. The legacy path (VME + PAK) runs
     motion estimation and rate control as closed-source shader kernels on the
     GPU's execution units. VDENC is a dedicated fixed-function block that needs
     no shader kernels.
   - The free-kernel driver only offers VDENC. h264_qsv's `low_power` defaults
     to `auto`, which on Gen12 asks for the legacy path, so the runtime rejects
     the session and every parameter is reported as "unsupported".
   - `-low_power 1` forces VDENC. Quality is close to the legacy path, though it
     has fewer tuning knobs, and it costs less power and EU load.
   - This is a capability check when the encoder starts. It has nothing to do
     with CPU C-states or power management.

To get the legacy encode path back, build the image with the non-free iHD
driver. `DispatcharrBase` takes an `FFMPEG_IMAGE` build argument for this.
Keeping `-low_power 1` is simpler.

## Container / iGPU passthrough

The cluster runs the Intel GPU device plugin. The app container requests
`gpu.intel.com/i915: 1` in `../helmrelease.yaml`, which mounts the node's
`/dev/dri/renderD128` (and `card1`) into the pod.

- The render node shows up as `root:root 0660`. Dispatcharr's uwsgi workers run
  as UID 1000 but hold supplementary GID 0 (plus 44/109), so the ffmpeg
  processes they spawn can open it. That covers both stream and output
  profiles, and no `supplementalGroups` change is needed.
- The image provides `iHD_drv_video.so` under
  `/usr/local/lib/x86_64-linux-gnu/dri` (`LIBVA_DRIVERS_PATH` is preset),
  libvpl 2.17 and the oneVPL GPU runtime (`libmfx-gen`).
- Only the `app` container requests the GPU. The `celery` container doesn't
  run stream or output profiles.
- Related Talos config: `talos/node/k8s-04/` patches and the schematic
  `talos/schematics/worker-intel-gpu.yaml.j2`.

## Testing a profile in the pod

Use a generated clip (force `format=yuv420p`: lavfi filters such as
`tinterlace` can negotiate 4:2:2, which the iGPU can't decode). Run ffmpeg as the
worker user so the device permissions match production. Check the final
`frame=` count in the log as well as the exit code: a broken video chain can
exit 0 with audio-only output.

```sh
kubectl -n default exec -it deploy/dispatcharr -c app -- bash
cd /tmp
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=1920x1080:rate=30000/1001 -f lavfi -i sine -t 15 \
  -vf format=yuv420p -c:v libx264 -preset veryfast -c:a ac3 -f mpegts in.ts

# Output profile: feed the clip on stdin, the way Dispatcharr does
setpriv --reuid=1000 --regid=1000 --groups=0,1000 \
  ffmpeg -hide_banner <output profile args> < in.ts > out.ts

# Stream profile: -user_agent is an HTTP option, so serve the clip over HTTP
/dispatcharrpy/bin/python -m http.server 18080 --bind 127.0.0.1 &
setpriv --reuid=1000 --regid=1000 --groups=0,1000 \
  ffmpeg -hide_banner <stream profile args, {streamUrl}=http://127.0.0.1:18080/in.ts, {userAgent}=test> > out.ts
kill %1

ffprobe -v error -show_entries stream=codec_type,codec_name,profile,avg_frame_rate out.ts
rm -f in.ts out.ts
```
