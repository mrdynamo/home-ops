# Dispatcharr Stream Profiles — NVENC vs Intel QSV

Notes for switching Dispatcharr's transcode stream profiles from NVIDIA NVENC to
Intel Quick Sync (QSV), since the Dispatcharr host uses an Intel iGPU.

Each profile set has 3 variants:
1. Uncapped FPS (passthrough source framerate)
2. Capped at 30 fps
3. Capped at 60 fps

## Original NVENC profiles

**Uncapped FPS:**
```
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -c:v h264_nvenc -preset p4 -profile:v high -pix_fmt yuv420p -rc cbr -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -sc_threshold 0 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**30 fps cap:**
```
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf fps=30000/1001 -fps_mode cfr -c:v h264_nvenc -preset p4 -profile:v high -pix_fmt yuv420p -rc cbr -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -sc_threshold 0 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**60 fps cap:**
```
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf fps=60000/1001 -fps_mode cfr -c:v h264_nvenc -preset p4 -profile:v high -pix_fmt yuv420p -rc cbr -b:v 8M -maxrate 8M -bufsize 16M -g 120 -keyint_min 120 -sc_threshold 0 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

## Converted Intel QSV profiles

Since Dispatcharr feeds ffmpeg raw MPEG-TS over pipes, QSV needs an explicit
hardware device init plus an `hwupload` filter to hand frames to the iGPU
before encoding. Adjust `/dev/dri/renderD128` if the container maps a
different render node.

**Uncapped FPS:**
```
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf format=nv12,hwupload=extra_hw_frames=64 -c:v h264_qsv -preset medium -profile:v high -look_ahead 0 -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**30 fps cap:**
```
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf fps=30000/1001,format=nv12,hwupload=extra_hw_frames=64 -fps_mode cfr -c:v h264_qsv -preset medium -profile:v high -look_ahead 0 -b:v 8M -maxrate 8M -bufsize 16M -g 60 -keyint_min 60 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

**60 fps cap:**
```
-fflags +discardcorrupt+genpts -probesize 512K -analyzeduration 1M -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i pipe:0 -map 0:v:0? -map 0:a? -sn -dn -vf fps=60000/1001,format=nv12,hwupload=extra_hw_frames=64 -fps_mode cfr -c:v h264_qsv -preset medium -profile:v high -look_ahead 0 -b:v 8M -maxrate 8M -bufsize 16M -g 120 -keyint_min 120 -c:a aac -b:a 384k -max_muxing_queue_size 4096 -flush_packets 1 -mpegts_flags +pat_pmt_at_frames+resend_headers+initial_discontinuity -f mpegts pipe:1
```

## Notes on the NVENC → QSV changes

- `-c:v h264_nvenc` → `-c:v h264_qsv`.
- `-preset p4` (NVENC's p1-p7 scale) → `-preset medium` (QSV's fast/medium/slow scale).
- Dropped `-rc cbr` and `-sc_threshold 0` — QSV doesn't expose `-rc`; `-look_ahead 0`
  combined with equal `-b:v`/`-maxrate` approximates constant bitrate instead.
- Added `-init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw` (global
  options) so ffmpeg can access the iGPU.
- Added `hwupload=extra_hw_frames=64` to each `-vf` chain (combined with the existing
  `fps=...` filter on the capped profiles) to move decoded frames onto the QSV surface
  before encoding.

## Open items

- Confirm `/dev/dri/renderD128` is passed through to the Dispatcharr container/pod
  and that the `intel_gpu`/`i915` VAAPI/QSV runtime is installed in the image.
- Check Dispatcharr Helm values for iGPU device passthrough (repo has existing
  intel-gpu Talos patches under `talos/patches/intel-gpu/` and schematic
  `talos/schematics/worker-intel-gpu.yaml.j2` for reference).
