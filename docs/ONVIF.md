# ONVIF IP cameras

A node discovers IP cameras on its network, cameras are configured on it at runtime, and
it vends each one to the cluster as a `:video_in` capability. The node proxies the
camera's stream: one RTSP connection per camera however many displays show it, and no
re-encoding.

## API

```elixir
# Discovery (WS-Discovery Probe for dn:NetworkVideoTransmitter)
Home.Onvif.discover()                                   # multicast 239.255.255.250:3702
Home.Onvif.discover(multicast: false, hosts: ["10.0.0.5"], timeout: 1_000)  # unicast
#=> [%Home.Onvif.Discovery{endpoint: "urn:uuid:...", xaddrs: ["http://10.0.0.5/onvif/device_service"],
#     name: "Porch", hardware: "...", types: [...], scopes: [...], from: {ip, port}}]

# Configure (on the node that should own the camera; rpc from elsewhere)
{:ok, {node, "porch"}} =
  Home.Onvif.add_camera("http://10.0.0.5/onvif/device_service",   # or "10.0.0.5", or a %Discovery{}
    username: "admin", password: "...",
    id: "porch",               # default "cam-<host>"
    profile: "main",           # token, name or index; default the first H.264 profile
    transport: :tcp,           # or {:udp, first_port, last_port}
    meta: %{name: "Porch"})    # merged into the capability meta

Home.Onvif.list_cameras()      # this node's cameras, without passwords
Home.Onvif.remove_camera("porch")
Home.Onvif.discovered()        # last periodic discovery result

# Use it like any video capability, from any node
{:ok, video} = Home.Render.show_video({node, "porch"}, on: {kitchen, "disp0"})
```

`add_camera/2` errors: `{:error, :unauthorized}` (wrong credentials),
`{:error, {:unreachable, reason}}`, `{:error, :already_exists}`, `{:error, :no_profiles}`,
`{:error, {:no_profile, p}}`, `{:error, {:unsupported_encoding, enc}}` (no H.264
profile, or the chosen one isn't H.264), `{:error, {:bad_stream_uri, uri}}`.

Periodic discovery: `Home` option `onvif: [discover_every: ms, discover: probe_opts]`.
Each round broadcasts `{:onvif_discovered, node, [%Discovery{}]}` on PubSub topic
`"onvif"` with the cameras found that are *not* configured on that node. Nothing is
added automatically. Off by default.

Relay status changes are broadcast on `"onvif"` as
`{:onvif_stream, {node, id}, :connecting | :streaming | {:retrying, reason}}`.

## Design

    camera (ONVIF + RTSP)          owning node A                            display nodes B, C
                                    Home.Onvif (config, ETS, file)
    SOAP  <----- add_camera ------  Home.Onvif.Client (ex_onvif)
                                    Home.Capability.add(%{kind: :video_in, shared: true,
                                                         availability: :on_request,
                                                         adapter: Home.Onvif.Camera})
    RTSP  <----- first lease -----  Home.Onvif.Relay (rtsp lib, 1 connection)
          ---- H.264 AUs -------->    fans AUs out to subscribers, caches GOP
                                    per media session:
                                      Home.Media.H264Relay -> H.264 parser
                                       -> RTP payloader -> muxer -> tee -> UDP  ---->  sink pipelines

* **Runtime capabilities** (`Home.Capability.add/1`, `remove/1`): a
  `Home.Capability.Runtime` DynamicSupervisor next to the static capability supervisor.
  A runtime capability is an ordinary `Home.Capability.Server`: it joins `:pg`, so it is
  in `Home.Registry.list/1` on every node as soon as `add/1` returns, and leaves it when
  stopped. `remove/1` revokes every lease (holders get `{:lease_revoked, ref}`, as for
  `Home.Lease.revoke_all/0`), turns the hardware off and stops the server. The static
  manifest path is unchanged. Runtime capabilities aren't persisted by `Home.Capability`;
  their owner (here `Home.Onvif`) re-adds them at boot.
* **Shared leases**: `Home.Capability` gained `shared:` (default `nil` = the kind's
  default). A camera is `shared: true`: every `show_video` takes its own lease and starts
  its own media session (its own source pipeline and payloader on A, fanning out over
  UDP to that session's sinks), but every session's source subscribes to the same
  `Home.Onvif.Relay`, so the camera sees one RTSP client.
* **Lifecycle**: `:on_request`. The first lease turns the hardware on, which starts the
  relay (RTSP DESCRIBE/SETUP/PLAY run in a task, so the capability server isn't
  blocked); the last release, the last holder dying, expiry, revoke or `remove_camera/1`
  turns it off, which stops the relay and sends TEARDOWN (bounded to ~2.5 s so a dead
  camera can't hold things up). The relay is linked to the capability server: a relay
  crash restarts the capability and ends every session on it.
* **Proxying**: the `rtsp` library depayloads RTP into access units (keyframes with
  SPS/PPS prepended). The relay re-emits them as annex-b with a monotonic nanosecond pts
  (continuous across reconnects) to each subscribed `Home.Media.H264Relay` source. The
  source pipeline's existing H.264 parser (NALu alignment, parameter sets repeated) and
  RTP payloader take it from there; nothing is decoded or encoded on A. The H.264 RTP
  path to the displays is the one VIDEO.md describes.
* **Joining sinks**: RTSP has no way to ask a camera for a keyframe, so the relay keeps
  the current GOP (last keyframe and every AU since, up to 2 MB). A new subscriber gets
  that GOP in one burst and then the live stream: its decoder reaches the live picture
  at once. If the GOP outgrows the cap (very long GOPs at high bitrate) a new subscriber
  waits for the next keyframe instead. The first subscriber after a (re)connect always
  waits for the camera's next keyframe.
* **Camera disconnects**: reconnect with exponential backoff (250 ms doubling to 30 s,
  for as long as the camera is leased). Sessions and leases stay up and the picture
  freezes meanwhile; status goes out on PubSub. Chosen over tearing down because
  cameras reboot and Wi-Fi drops, and the display should come back by itself. To give
  up on a camera, release the lease or `remove_camera/1`.
* **Credentials**: stored only on the owning node, in `<data_dir>/onvif_cameras`
  (Erlang term file, mode 0600, not encrypted at rest - same as `Home.Secrets`), and in
  a protected ETS table read by the adapter when it starts the stream. They are never
  in the capability (whose meta every node reads), never in `Home.Secrets`, and
  `list_cameras/0` leaves the password out. `add_camera/2` called over rpc carries them
  once to the owner. They go into the RTSP URI's userinfo for the camera (RTSP basic or
  digest is handled by `membrane_rtsp`).
* **Boot**: `Home.Onvif` reads the file and re-adds every camera without contacting it
  (it may be offline; the stream connects on the first lease and retries).

Capability meta: `source: :onvif`, `codec: :h264`, `w`, `h`, `fps`, `bitrate` (kbit/s, as
the camera reports), `profile` (token), `manufacturer`, `model`, `firmware`, `onvif` (the
device service URL), plus `meta:` from `add_camera/2`.

## Libraries

* [`ex_onvif`](https://hex.pm/packages/ex_onvif) 0.9 (from ExNVR): the SOAP calls
  (`Devices.get_system_date_and_time/get_device_information/get_services`,
  `Media.get_profiles/get_stream_uri`) with WS-Security UsernameToken digest, HTTP
  digest and basic auth. `Home.Onvif.Client` adds the parts ExNVR does in its own code:
  keeping the URL's device service path, picking the media service address from
  `GetServices`, trying auth schemes in order and mapping faults to `:unauthorized`.
  It pulls in ecto, tesla, finch and sweet_xml.
* [`rtsp`](https://hex.pm/packages/rtsp) 0.8 (ExNVR's RTSP client, on `membrane_rtsp`):
  TCP interleaved or UDP, RTP depayloading and H.264 access-unit assembly, keep-alives.
  ExNVR's pipelines use the same library.
* WS-Discovery: `ExOnvif.Discovery` only probes by multicast and keeps its parser
  private, so `Home.Onvif.Discovery` builds the probe and parses `ProbeMatch`es itself
  (SweetXml), to support unicast probes to given hosts.

## Tests

`test/onvif_test.exs`, three peers (`mo*`, media ports 42100..42159), with a fake camera
on the test node from `test/support`:

* `Home.Test.FakeOnvif`: device and media services over Bandit that check the
  WS-Security PasswordDigest on every call but `GetSystemDateAndTime` (`ter:NotAuthorized`
  fault otherwise), two profiles (JPEG sub stream, H.264 main), and a WS-Discovery
  responder on a UDP port.
* `Home.Test.FakeRtspCamera`: a `Membrane.RTSP.Server` that streams x264-encoded
  `Home.Media.SynthVideo` (frame numbers drawn in, capture times reported) to every
  client over TCP interleaved, mid-GOP like a real camera, counting RTSP sessions.
  Chosen over mediamtx + ffmpeg because it needs no binaries and the frame numbers give
  exact camera-to-display latency with the existing `VideoHelpers.watch/4`.

Numbers on this VM (320x240 @ 30 fps, GOP 1 s, peers on 127.0.0.1, headless displays):

| | |
|---|---|
| camera capture -> frame readable on the display (other node) | median 72 ms, p95 74 ms |
| `show_video` -> first frame, first viewer | 0.2 - 0.9 s (RTSP setup + wait for the camera's next keyframe; bounded by its GOP) |
| `show_video` -> first frame, later viewer (cached GOP) | 60 - 70 ms |
| RTSP connections with 3 displays on 2 nodes | 1 |
| camera drops the connection | reconnects after 250 ms, picture back at the next keyframe |

The latency equals the synthetic-camera path in VIDEO.md (71 ms): the relay adds no
measurable delay.

## Limits / not done

* H.264 only. H.265 and MJPEG profiles are rejected (`{:unsupported_encoding, _}`);
  H.265 would need an H.265 RTP path in `Home.Media`.
* Video only; camera audio tracks aren't requested.
* The multicast probe isn't covered by tests (loopback multicast isn't available here);
  the unicast path, parser and periodic discovery are.
* The fake camera's RTSP doesn't require auth, so RTSP digest auth (handled by
  `membrane_rtsp` from the URI userinfo) isn't exercised by the tests. Not tested
  against a real camera or mediamtx on this host.
* Media2 (`ver20`) profiles aren't used; cameras that only offer Media2 aren't supported.
* Stream URIs that expire (`InvalidAfterConnect`) aren't refreshed; the stored URI is
  reused on every connect. Re-run `add_camera/2` after a camera's address changes
  (remove first).
* No PTZ, events, snapshots or recording.
* The credentials file isn't encrypted at rest (same as `Home.Secrets`).
* A late joiner's GOP burst is sent at once; with long GOPs on a slow link that is a
  burst of up to 2 MB per joining session.
