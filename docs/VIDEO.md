# Video sessions and video surfaces (M5)

PLAN §5 (H.264 media sessions), §6.3 (video as a surface) and §6.2 (pixel forwarding).

## What emerge already has (no emerge change needed)

Read against the `home-scene-forwarding` branch of `/root/workspace/emerge-home`
(emerge 0.5.0 plus the M4 hooks) and its precompiled 0.5.0 NIF:

* `Emerge.UI.video(attrs, target)` is a video element; `target` is an atom, encoded into
  the tree bytes as the string attr `video_target`.
* `EmergeSkia.submit_video_frame(renderer, target, %VideoInterop.Frame{})` hands a frame
  to that element. Binary frames (`VideoInterop.Frame.binary/2`, one plane, `:rgba8888`,
  `:rgb888`, `:gray8`, ...) are accepted by every backend including headless; DMA-BUF
  frames need the `video-interop-support` build. A target not in the current tree (or
  hidden) drops the frame; a visible one keeps only the latest. The renderer redraws on
  submit, so a headless output emits a new `{:emerge_skia_frame, frame}` per video frame.
  (`Emerge.submit_video_frame/3` is the same through a viewport.)
* Headless output frames are `VideoInterop.Frame`s with `storage.data` RGBA, which is
  what pixel forwarding encodes.

So the "VideoSurface node" of §6.3 exists. The only missing piece was a Membrane sink
that feeds it, which is ordinary home_base code (`Home.Media.VideoSink`). The one thing
emerge can't do is take injected pointer input into a headless renderer (see limits).

## Shape

    camera node A                         display node B                    caller node C
    SynthVideo/CameraCapture              UDP -> RTP demux -> H.264 depay   Home.Render.Video
     -> SWScale to I420                    -> H.264 parser (AU)              (render session +
     -> x264 (ultrafast, zerolatency,      -> FFmpeg H.264 decoder            owner of the
        baseline, no B, gop 30,            -> SWScale to RGB                  media session)
        CRF capped by maxrate/bufsize)     -> Home.Media.VideoSink
     -> H.264 parser (NALu)                   -> Compositor.video_frame/4
     -> RTP H.264 payloader -> muxer              -> EmergeSkia.submit_video_frame
     -> tee -> UDP

* **Media**: `Home.Media.Session.start(source: cam_lease, sink: display_lease,
  codec: :h264, surface: {render_session, target})`. Same session, same lifecycle,
  same port allocation and fan-out (tee) as M2; the pipelines get an H.264 branch.
  The display lease's endpoint is the compositor pid; `Home.Media.start_sink/2` turns it
  into a `%Home.Media.VideoSink{}` when `codec: :h264` and `surface:` are given.
  H.264 uses `membrane_h264_ffmpeg_plugin`, `membrane_h26x_plugin` (parser),
  `membrane_rtp_h264_plugin` with the RTP.Muxer/Demuxer M2 already uses (payload type
  96, 90 kHz), and `membrane_ffmpeg_swscale_plugin` for pixel formats.
* **Surface**: `Home.Render.Video` is, to the compositor, an ordinary render session
  (attach / upload / resync / input, M4's protocol) whose tree is one full-size
  `video` element with target `:home_video`, encoded with
  `Emerge.Engine.encode_full/2`. It stacks with scene-forwarded apps (latest on top);
  the compositor submits a frame only while its session is the one drawn, so a hidden
  video costs no drawing and doesn't flicker over the app on top.
* **API**: `Home.Render.show_video(cam_lease_or_ref, on: {b, "disp0"})` and
  `Home.Render.show_pixels({viewport_module, opts}, on: {b, "disp0"})`, both returning
  the `Home.Render.Video` pid; `Home.Render.stop/1` and `target/1` work on it.
* **Pixel forwarding**: the app runs on the caller's node with the same `runtime:` option
  as scene forwarding, but the adapter is `Home.Render.Pixels`: the stock emerge
  renderer with the output swapped for headless at the display's size (from the display
  capability's `meta.w/h`), targeting a `Home.Media.FrameSource` in the session's source
  pipeline. The frame source resamples to a constant 30 fps (latest frame, repeated),
  then the same H.264/RTP path goes to B. Input on B goes back over distribution
  (compositor -> `Home.Render.Video` -> app) as native `{:emerge_skia_event, ev}`, i.e.
  "the same way as §6.1". A non-emerge app gets the frame sink and size in
  `opts[:runtime][:adapter_opts]`, sends `{:emerge_skia_frame, frame}` itself and gets
  the same input messages.
* **Lifecycle**: the media session holds the camera and display leases and renews them;
  it monitors pipelines, capability servers and its owner (the video process). Either
  node dying, a revoke or expiry ends the media session; the video process monitors it
  and stops (detaching from the compositor; the app too, for pixels). Stopping the
  video process stops the media session, which terminates the camera's pipeline:
  `Membrane.CameraCapture` closes the device and an `:on_request` camera turns off.

## Negotiation (`Home.Media.Video`)

Cameras and displays say what they can do, and a video session settles one stream that
both ends manage before it starts anything.

* **Support**: every `:video_in` and `:display` has `video:` in its registry info:
  `%{encode: [%Home.Media.Video.Format{}]}` or `%{decode: [...]}`. A format is a codec
  (`:h264`), `hardware`, what runs it (`element`: `:software`, `:relay`, or a decoder
  filter), `profiles`, `max_level` (`level_idc`), `max_size`, `sizes`, `max_fps`,
  `max_bitrate`, and an encoder's defaults (`size`, `fps`, `bitrate`). An adapter states
  its own (`c:Home.Adapter.video/1`: a phone camera encoded by Venus, an ONVIF camera);
  otherwise a camera is x264's at its meta size and rate, and a display has its node's
  decoders (`config :home_base, video: [decoders: [...]]`, then FFmpeg).
  `Home.Media.Video.list/1` shows the cluster's; `describe/1` puts one in a line.
* **Settling**: `Home.Media.Video.negotiate/3` tries the source's encoders (hardware
  first), each of its profiles in order, and sizes from the one wanted down (an encoder
  that scales tries the decoders' limits and a ladder of smaller sizes; one with a list
  of `sizes` tries those), and takes the first stream every sink has a decoder for:
  profile accepted, size within `max_size`, frame rate within `max_fps`, and the level the
  size and rate need (Table A-1) within `max_level`. The result is a
  `Home.Media.Video.Path`: the stream, the encoder, and each sink's decoder.
* **Hardware first, failure otherwise**: by default (`decoder: :auto`) a sink whose node
  has hardware decoders only uses those. A stream they can't take is
  `{:error, {:no_video_path, reasons}}` (`explain/1` gives them in words), never a
  silent fall back to slow software. `decoder: :software` is the override, for the
  device that asks: that sink decodes with FFmpeg, and the source sends the same.
  `:hardware` refuses software even where it's all a node has.
* **Doing it**: the source sends the path: x264 gets its profile and is scaled to its
  size; a `Home.Media.H264Relay` subscribes to its feed with the path's size, frame rate
  and bitrate (`{:subscribe, pid, params}`) so a camera with its own encoder starts that
  stream. Each sink pipeline decodes with the decoder chosen for it. A sink added to a
  running session (`add_sink/3`, `Home.Render.move/2`) must take the running stream
  (`accepts/4`).
* **Dry run**: `Home.Media.Video.check(source_ref, sink_refs, opts)` negotiates from the
  registry without leasing anything.

Nodes running a home_base from before this have no `video:`: their cameras count as
x264's and their displays as decoding their own way, and their pipelines ignore the
path. Tests: `test/media_video_test.exs` (the rules), `test/video_negotiation_test.exs`
(a display whose "hardware" takes at most 640×480: a 720p x264 camera is scaled to
640×360, a fixed 720p high-profile stream is refused unless that display decodes in
software, and a display that can't take a running stream can't join it).

## Adapters

* `Home.Adapters.Video.SynthCamera` (`Home.Media.SynthVideo`): real-time paced I420 test
  pattern (moving bar) with the frame number and a check byte drawn as 32 black/white
  blocks; `SynthVideo.decode/2` reads it back from an RGB(A) picture (scaled with
  `:contain`), and the source sends `{:synth_frame, cap, n, wall_us}` per frame.
* `Home.Adapters.Video.Camera`: `Membrane.CameraCapture` (FFmpeg v4l2/avfoundation),
  meta `device`, `w`/`h`, `fps`, `pixel_format` (default `yuv420p`; anything else is
  converted to I420). Tested against v4l2loopback fed by ffmpeg (`test/v4l2_camera_test.exs`,
  tag `:v4l2`, excluded by default; it `modprobe`s `v4l2loopback video_nr=42`).

## Numbers (this VM, peers on 127.0.0.1, headless raster displays)

Latency is camera capture time (`{:synth_frame, ...}`) to the frame number first being
readable in B's latest headless frame (polled every ~2 ms), same wall clock:

| case | frames shown | median | p95 | max |
|---|---|---|---|---|
| 320x240 @ 30 fps | 89 of 90 in 3 s | 6 ms | 7 ms | 17 ms |
| 1280x720 @ 30 fps, 3 Mbps cap | 89 of 90 in 3 s | 27 ms | 30 ms | 57 ms |
| pixel forwarding: click on B -> app on A -> new colour on B (320x240) | 6 rounds | 33 ms | | 33 ms |

Target is <= 250 ms (§5.3). The frame "missing" is the one in flight when the 3 s window
closes. The jitter buffer only holds packets on a sequence gap.

Before access units were cut on the RTP marker the same cases measured 71/72 ms, 82-92 ms
and 99 ms: `Membrane.RTP.H264.Payloader` held each frame's small NAL units in a STAP-A
until the next frame's first one arrived, and on the receiver `Membrane.H264.Parser`
waited for the next access unit too (the stock depayloader copies a STAP-A's marker
onto every NAL unit in it, so the marker couldn't be used there). `Home.Media.H264Payloader`
sends each access unit at once with the marker on its last packet, and
`Home.Media.H264Depayloader` hands each access unit on when its marker arrives: two
frame intervals less at 320x240, where whole frames fit in one STAP-A.

### Loss (`test/media_resilience_test.exs`, `Home.Test.LossyRelay` between source and sink)

RTCP runs on the RTP ports (`Home.Media.RTCP`): SRs from the source, RRs, generic NACKs
and PLIs from each sink. `Home.Media.Session.stats/1` has both ends' view.

| case | feedback | result |
|---|---|---|
| 320x240 video, gop 90, 200 ms blackout | none | first frame 1.64 s after the blackout (next periodic keyframe) |
| same | PLI | 74 ms (one forced keyframe) |
| same | NACK + PLI | 10-18 ms (the lost packets are resent; no keyframe needed) |
| audio, 5% random loss, 8 ms jitter | none | 7 of 199 packets lost, RR fraction 0.059, jitter 3.9 ms |
| same | NACK | 0 of 199 lost (7 resent and recovered), RTT ~8 ms (incl. relay delay) |

After a loss the receiver drops frames until a keyframe (a frozen picture rather than a
smeared one) and sends a PLI, repeated every 250 ms while it waits.

A packet the sending socket refuses is a loss too. `Membrane.UDP.Endpoint` raised on any
send error, so a keyframe burst that filled the socket's send buffer (`:eagain`, seen
from a camera node sending to a phone) ended the whole session. Both pipelines use
`Home.Media.UDPEndpoint` instead, which drops that packet, counts it and logs at most
every 5 s; NACKs and PLIs recover it like any other.

## Limits / not done

* An emerge app under pixel forwarding gets raw input (`handle_input/2`: pointer,
  keys) but not element events (`Event.on_press`): those need hit-testing in A's
  headless renderer, and emerge has no API to inject pointer input into a running
  renderer (the NIF only has it for its test harness). Upstream-able, but a NIF change
  (not usable with the precompiled 0.5.0 NIF), so not done. Scene forwarding (§6.1)
  remains the way to get element events remotely.
* Pixel forwarding renders at the display's size, so pointer coordinates map 1:1. A
  display without `meta.w/h` gets 800x600 and letterboxed coordinates are not mapped.
* `move/2` on a video adds the new display to the media session (the source forces a
  keyframe once the new sink's endpoint is linked) and then removes the old one: first
  frame on the new display ~12 ms after the call, the camera keeps running. A pixel app
  keeps rendering at the first display's size.
* A forwarded app can contain its own `video/2` element, and the compositor will feed
  any session's target from `Compositor.video_frame/4`, but there is no API yet to aim a
  camera at an element of a scene-forwarded app (it would have to follow `move/2`).
* Retransmissions resend the same packets (no RTX stream, RFC 4588), and only within
  the jitter buffer's wait (`jitter`, 40 ms); there is no congestion control (REMB/TWCC)
  and no FEC.
* The bitrate is a VBV cap on CRF (`maxrate`/`bufsize` = bitrate/2), not a target; the
  synthetic pattern is far below it.
* Hardware H.264 (rpicam-vid / V4L2 M2M on the Pi) is not wired; the encoder is x264.
