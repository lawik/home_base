
  
    Markdown · home-cluster-plan.md
    

## Home Cluster Plan
    
  

  

Status: draft, 2026-10-19
Owner: Lars
Audience: coding agents implementing this. Read the whole thing before starting a milestone.


## 1. Goal and shape


A small set of home devices, each running Elixir — Nerves boxes, laptops, desktops, a server, a phone or tablet if it can run the BEAM, anything else that can — find each other, form one Erlang cluster of equals, and lend each other hardware: microphones, speakers, displays, cameras, Thread/Zigbee radios, sensors, presence detection. Any device with a screen can render any app via emerge. Any audio or video source can be piped to any sink via Membrane. Devices that should not always be listening (a laptop, a phone) expose their mic/camera as activatable: hardware is off until a lease starts it, and is closed again on release, on holder death, or when a safety timeout runs out. No prompts, no dialogs.


The design mirrors Apple Continuity's three layers, on the BEAM over a tailnet:



|
Layer |
Apple |
Us |



|
Discovery |
BLE beacons + AWDL |
Tailscale peer list (tagged nodes on one tailnet) |


|
Trust |
iCloud identity |
Tailscale identity + Erlang cookie |


|
Transport |
AWDL peer-to-peer Wi‑Fi |
Erlang distribution for control, UDP/RTP for media, both over the tailnet |




## Constraints that drive the design


- Home scale: fewer than ~20 nodes, one tailnet, one owner. Full-mesh distribution and a shared cookie are acceptable. Nodes need not share a LAN; a laptop away from home is still a member.

- Mesh of equals: there is no hub, coordinator or server role. Every node runs the same home_base app; what differs is its manifest. Nothing in the first milestones needs a cluster-wide singleton.

- Capabilities are static per device for now. No hot-plug detection, no negotiation.

- Hot code updates are a separate effort. Out of scope.

- Placement (room/area) comes from Home Assistant, not from sensing.

- Every node runs tailscaled and is tagged tag:homecluster.

- ESP32/AtomVM devices are out of scope for now. How they attach is undecided.



## Non-goals


- Compatibility with Apple Continuity, Matter, or any external protocol.

- Clustering across tailnets, or without Tailscale.

- Authorization beyond "in the cluster = trusted". No per-use consent prompts; the only guard on activatable hardware is the lease lifecycle and its safety timeout (§4.4).



## 2. Discovery and clustering


Discovery is Tailscale. Every node is on the same tailnet, tagged tag:homecluster; the peer list from the local tailscaled is the membership list. No mDNS, no multicast, no beacons.


## 2.1 Node naming


Use the Tailscale IP: home@100.101.102.103. Tailscale IPs are stable per device for the life of the tailnet membership, and reachable whether the device is on the home LAN, on Wi‑Fi elsewhere, or on mobile data. MagicDNS names also work but add a resolver dependency; use the IP.


- Nerves: start :net_kernel with --name home@<tailscale ip> once the Tailscale interface has an address (watch for the tailscale0 interface via VintageNet or poll the local API).

- Any other host: same, via the release's start script, reading the IP from tailscale ip -4.



## 2.2 Membership


Module: Home.Cluster.


- Query the tailscaled local API (GET /localapi/v0/status, over the Unix socket on Linux/macOS; equivalently tailscale status --json). Take Peer entries whose Tags include tag:homecluster and that are Online.

- For each peer not yet connected: Node.connect(:"home@<TailscaleIPs[0]>").

- Node.monitor/2 every connected node; re-query the local API on nodedown and every 30 s.

- All nodes mesh fully. No node is special; any node can discover and connect any other.



Erlang distribution listens on a fixed port (inet_dist_listen_min/max set to one value, e.g. 4370) bound to the Tailscale interface only. epmd is still needed locally for the handshake; keep it, or use -start_epmd false with -erl_epmd_port on every node since the port is fixed. Tailscale ACLs: allow tag:homecluster → tag:homecluster on that port plus the UDP media range (§5).


Cookie: one shared cookie baked into each firmware / release config. Tailscale encrypts and authenticates the link, so the cookie is only guarding against other tailnet devices; TLS distribution is deferred further than it would be on a plain LAN.


## 2.3 Why not mDNS


mDNS only covers one broadcast domain and dies on VLANs, Wi‑Fi isolation and anything off-site. Tailscale gives a flat address space and a membership list for free. The cost is that every node must run tailscaled; see open questions for the Nerves side.


## 2.4 BLE (optional, later)


BLE could seed Wi‑Fi/Tailscale credentials onto a fresh device. Never run distribution or media over BLE. Skip in the first milestones.


## 3. Capability registry


## 3.1 Manifest (static per device)


Each device ships a manifest, loaded from config at boot. Example:

```
%Home.Manifest{
  device_id: "nerves-kitchen-01",
  node: :"home@192.168.1.23",
  capabilities: [
    %Home.Capability{id: "mic0", kind: :audio_in,  availability: :always,     meta: %{channels: 1, rate: 48_000}},
    %Home.Capability{id: "spk0", kind: :audio_out, availability: :always,     meta: %{channels: 2, rate: 48_000}},
    %Home.Capability{id: "disp0", kind: :display,  availability: :always,     meta: %{w: 1024, h: 600, touch: true}},
    %Home.Capability{id: "cam0", kind: :video_in,  availability: :on_request, meta: %{w: 1280, h: 720, fps: 30}},
    %Home.Capability{id: "zb0",  kind: :zigbee,    availability: :always,     meta: %{coordinator: true}},
    %Home.Capability{id: "thr0", kind: :thread,    availability: :always,     meta: %{border_router: true}},
    %Home.Capability{id: "pir0", kind: :presence,  availability: :always,     meta: %{sensor: :pir}},
    %Home.Capability{id: "temp0", kind: :sensor,   availability: :always,     meta: %{measures: [:temperature, :humidity]}}
  ]
}

```



Capability kinds (closed set, extend deliberately): :audio_in, :audio_out, :video_in, :display, :input (touch/keyboard/pointer), :zigbee, :thread, :sensor, :presence.


availability:


- :always — vended as soon as the node is up.

- :on_request — hardware is off; a lease starts it, and release/holder death/safety timeout stops it (§4.4).

- :off — present but disabled by the owner; never vended.



## 3.2 Registry


Module: Home.Registry, one per node, backed by :pg.


- Each node joins :pg group {:capability, kind} with one process per capability (Home.Capability.Server). The process's state is the capability struct plus runtime status (:idle | :leased | :starting | :error).

- Home.Registry.list(kind: :audio_out, area: "kitchen") → walks :pg members, calls each for its struct (cache with a short TTL; these change rarely).

- Registry changes are broadcast on Phoenix.PubSub topic "registry" as {:capability_up, cap} / {:capability_down, cap_ref}.



A capability reference used everywhere else: {node, cap_id}.


## 3.3 Placement from Home Assistant


Every node asks HA for its own area; there is no sync coordinator and no elected singleton. Area is runtime state learned from HA, never configuration.


- Devices that report to HA do so via homex over MQTT (already in place). Devices that need HA data pull it themselves over HA's WebSocket/REST API using the shared HA token (§4.5).

- At boot (and then every few hours, or on explicit Home.Registry.refresh_area/0), the node calls config/device_registry/list + config/area_registry/list, finds its own device by the same device_id it uses in its MQTT discovery identifiers, resolves area_id → area name, and stores it in its own registry entry. Placement changes rarely, so a slow refresh is fine.

- The node persists the last known area so it survives HA being down. Until the first successful lookup, area is nil: the node is a full peer, it just can't be addressed by room. Area-scoped queries skip it; cluster-wide ones include it. There is no manifest fallback, because devices aren't provisioned for a location.



## 4. Device baseline system


Every device runs the same OTP app, home_base, which enables all hardware it has and vends it. Device differences live in config, not code. A device with no hardware to vend (a headless server) still runs it and is a full peer: it can hold leases, run apps that render elsewhere, and host media sessions.


## 4.1 Structure

```
home_base/
  lib/home/cluster.ex            # §2 Tailscale peer discovery
  lib/home/registry.ex           # §3
  lib/home/capability.ex         # struct + behaviour
  lib/home/capability/server.ex  # per-capability process, lease owner
  lib/home/lease.ex              # §4.3
  lib/home/lease/watchdog.ex     # §4.4 safety timeout
  lib/home/media/*               # §5
  lib/home/render/*              # §6
  lib/home/activity.ex           # §7 activity events + store
  lib/home/secrets.ex            # §4.5 shared credential store
  lib/home/ha/client.ex          # §3.3 HA API client (per node)
  lib/home/adapters/<kind>/*.ex  # hardware adapters

```



## 4.2 Adapter behaviour

```
defmodule Home.Adapter do
  @callback init(Home.Capability.t()) :: {:ok, state} | {:error, term}
  @callback start(state) :: {:ok, state}      # turn hardware on / start vending
  @callback stop(state)  :: {:ok, state}      # turn hardware off
  @callback endpoint(state) :: term           # kind-specific handle: a Membrane child spec, a display surface, a sensor read fun...
end

```



One adapter module per {kind, platform}, chosen in config:



|
Kind |
Nerves (RPi) |
Plain Linux/macOS host |



|
audio_in / audio_out |
membrane_portaudio_plugin or ALSA via membrane_alsa |
membrane_portaudio_plugin |


|
video_in |
membrane_camera_capture_plugin (V4L2) or rpicam-vid piped into Membrane |
membrane_camera_capture_plugin |


|
display |
emerge native backend (framebuffer/DRM) |
emerge window |


|
input |
existing emerge input path |
existing emerge input path |


|
zigbee |
existing coordinator lib / zigbee2mqtt bridge |
n/a |


|
thread |
OTBR on the device, control via its REST/DBus |
n/a |


|
sensor / presence |
GPIO / I²C via circuits_* |
n/a |




Adapters for zigbee/thread only need to announce in the first milestones; actual command routing is later.


## 4.3 Leases


All use of a capability goes through a lease. Module Home.Lease.

```
{:ok, lease} = Home.Lease.acquire({node, "mic0"}, for: self(), purpose: "intercom to living room", timeout: 10_000)
# lease = %Home.Lease{ref, cap, holder, endpoint}
:ok = Home.Lease.release(lease)

```



- The Capability.Server on the owning node is the single lease owner. Exclusive by default; :shared allowed for :audio_out (mixing) and :display (compositor handles layering).

- The server monitors the holder pid; holder death releases the lease and stops the hardware if it was :on_request.

- acquire/2 on an :on_request capability starts the hardware (adapter start/1) before returning the endpoint; the last release stops it (stop/1).

- Lease state is broadcast on PubSub "leases" so UIs can show "kitchen mic in use by living room".



## 4.4 Safety timeout (closing the device)


There is no consent dialog. The rule is simply: hardware that was off goes back off as soon as nothing legitimately needs it.


- Every lease has a max_age (default 10 min for :audio_in/:video_in, 60 min for everything else, configurable per capability in the manifest). Home.Lease.Watchdog on the owning node expires leases past max_age, stops :on_request hardware if that was the last lease, and sends {:lease_expired, ref} to the holder.

- Holders doing something long-running (a call) call Home.Lease.renew(lease) periodically; renewing resets the clock. A holder that stops renewing is treated as gone.

- Holder death (process exit, node down) releases immediately via monitor; the watchdog is the backstop for a holder that is alive but stuck.

- A node-local Home.Lease.revoke_all/0 drops every lease on this node and stops its :on_request hardware (:always hardware stays on; nothing would turn it back on). Expose it as a function and, where there is a UI, a button or hotkey; no confirmation.

- Lease state and hardware on/off are broadcast on PubSub "leases" so any display can show a small "mic on, held by " indicator. That indicator is the entire transparency story for now.



## 4.5 Shared credentials


Rule: any credential that is not per-device is the same on every node and is copied to all of them. Per-device credentials (the Tailscale node key, a device's own MQTT identity if one exists) stay local.


- Shared set: HA long-lived token, HA URL, MQTT broker URL/user/password, the Erlang cookie, any third-party API keys the apps need.

- Module Home.Secrets: a small :pg-registered KV with a version. Home.Secrets.get(:ha_token) reads the local copy; Home.Secrets.put(key, value) on any node bumps the version and broadcasts the whole set on PubSub "secrets". Nodes that join later ask any peer for the current set on nodeup and take the highest version.

- Persist locally in the node's writable data dir (Nerves: /data, elsewhere the app's config dir) so a node boots with the last set before it reconnects.

- The first copy gets in by whatever already provisions the device (baked into firmware/config, or Home.Secrets.put/2 from any node's console). Rotation = put/2 once, anywhere.

- No encryption at rest on the first pass; the tailnet and the cookie are the perimeter. Note it as deferred.



## 5. Audio and video over the cluster (Membrane)


## 5.1 Two channels, not one


- Control over Erlang distribution: lease, session setup, start/stop, stats.

- Media over a dedicated UDP socket using RTP (membrane_rtp_plugin) on the Tailscale IPs, negotiated over distribution. Same-LAN peers get a direct WireGuard path; off-site ones may relay through DERP, which raises latency — the targets in §5.3 assume a direct path. Distribution is a single TCP stream per node pair with no per-message flow control; pushing raw audio/video through it will stall :pg, leases, and everything else. Only tiny, low-rate streams (sensor values) go over distribution.



## 5.2 Session setup


Module Home.Media.Session.


- Caller holds leases on a source and a sink (e.g. {a, "mic0"} and {b, "spk0"}).

- Home.Media.Session.start(source: lease_a, sink: lease_b, codec: :opus).

- Sink node opens a UDP port, replies with {ip, port, ssrc}.

- Source node starts a pipeline: adapter endpoint → encoder → RTP payloader → Membrane.UDP.Sink to that address.

- Sink node starts: Membrane.UDP.Source → RTP depayloader → decoder → adapter endpoint.

- The session process on the caller's node monitors both pipelines and both leases; any death tears the whole thing down.



Codecs: Opus for audio (membrane_opus_plugin), H.264 for video (membrane_h264_ffmpeg_plugin; on RPi prefer the hardware encoder via rpicam-vid --codec h264 piped to Membrane). Keep bitrates conservative on first pass (Opus 64 kbps, H.264 2–4 Mbps at 720p).


## 5.3 Fan-out and mixing


- One source → many sinks: start one encoder and one RTP payloader, tee to N UDP sinks. Don't re-encode per sink.

- Many sources → one speaker: the :audio_out adapter owns a Membrane.AudioMixer; each shared lease gets its own input pad.

- Latency targets: ≤ 150 ms end-to-end for intercom-style audio, ≤ 250 ms for video. Measure before optimizing; log RTP jitter and buffer occupancy.



## 5.4 Clock and sync


Not required for the first milestones. When multi-room synced playback is wanted, add a cluster-wide clock (NTP/PTP on the LAN or a simple round-trip-corrected :erlang.monotonic_time exchange) and RTCP sender reports. Note it; don't build it yet.


## 6. Remote rendering with emerge


emerge already renders headlessly. Two forwarding modes; implement in this order.


## 6.1 Scene forwarding (primary)


The app runs on node A. Instead of drawing locally, emerge serializes its render tree (initial full tree, then diffs per frame) and sends it to a Home.Render.Compositor on node B, which draws it with B's local emerge backend. Input events (touch/pointer/key) from B are sent back to A.


- Transport: Erlang distribution is fine here. Diffs are small and bursty, not a constant stream. If a scene produces more than a few hundred KB/s sustained, fall back to §6.2.

- B must have the fonts and image assets A references. Add an asset manifest step: A sends {:assets_needed, [hash]}, B replies with what it lacks, A streams them once (over a TCP socket if large). Cache on B's disk keyed by hash.

- A lease on {b, "disp0"} (and {b, "input0"}) is required. Shared display leases are layered by the compositor (z-order = lease order, latest on top; make this configurable later).

- API: Home.Render.show(app_spec, on: {b, "disp0"}) returns a session pid; Home.Render.move(session, to: {c, "disp0"}) migrates the same app to another display without restarting it (A keeps running; only the target compositor changes).



## 6.2 Pixel forwarding (fallback)


Headless render on A → raw frames → H.264 → RTP/UDP → B decodes into an emerge video surface (§5). Use for non-emerge content (a browser, a video player) or when scene forwarding can't keep up. Input events go back the same way as §6.1.


## 6.3 Video as a surface


Video from a :video_in lease is just a media session (§5) whose sink is an emerge video surface on the target display. emerge needs a VideoSurface node that accepts decoded frames from a Membrane sink. This is the one piece of emerge work that is required rather than optional.


## 7. Activity (recency data)


Module Home.Activity. This records when each capability was last active and in what way, per capability, cluster-wide. It does not interpret the data, pick a "focused" device, or decide what presence means. That is policy and is decided later.


## 7.1 Event


Every capability emits activity events to PubSub "activity":

```
%Home.Activity.Event{
  cap: {node, cap_id},
  kind: :input | :display | :audio_in | :audio_out | :video_in | :presence | :sensor | :lease,
  event: atom,             # kind-specific, see table
  ts: integer,             # :erlang.system_time(:millisecond) on the emitting node
  mono: integer,           # :erlang.monotonic_time(:millisecond) on the emitting node, for ordering within a node
  area: String.t() | nil,  # the node's area at emit time
  data: map                # kind-specific, raw
}

```



Kinds and the events each one emits:



|
kind |
event |
data |
emitted by |



|
:input |
:touch, :pointer, :key, :scroll |
%{session: pid | nil} — which render session received it, if any |
emerge input path |


|
:display |
:frame, :session_started, :session_stopped, :blank, :unblank |
%{session: pid | nil, fps: float | nil} |
compositor |


|
:audio_in / :audio_out / :video_in |
:stream_started, :stream_stopped, :level |
%{session: pid, level_db: float} for :level |
Membrane pipeline |


|
:presence |
:detected, :cleared |
%{sensor: atom, confidence: float | nil} |
sensor adapter |


|
:sensor |
:reading |
%{measure: atom, value: number, unit: atom} |
sensor adapter |


|
:lease |
:acquired, :released, :renewed, :expired, :revoked |
%{holder: pid, holder_node: node} |
Home.Lease |




Rate limits are per {cap, kind, event}, set by the adapter, not globally: :input events coalesce to at most one per 250 ms per cap; :display :frame to one per second with the fps in data; :level to one per second. Start/stop and lease events are never coalesced.


## 7.2 Store


Every node keeps the same in-memory table (ETS, keyed by {cap, kind}) with the latest event per key, plus a bounded ring of the last N events per key (N = 64, configurable). Updated by subscribing to "activity"; a node that joins late asks any peer for a snapshot. Last-writer-wins by ts.


Query API, deliberately dumb:


- Home.Activity.last(cap, kind) → latest event or nil.

- Home.Activity.last(kind: :input) → latest event per cap for that kind, cluster-wide.

- Home.Activity.last(kind: :input, area: "kitchen") → same, scoped by the event's area.

- Home.Activity.since(cap, kind, ms) → events in the last ms.

- Home.Activity.subscribe(kind | cap) → receive events as they arrive.



Clock note: ts is wall-clock on the emitting node. Nodes run NTP (Nerves does by default), so cross-node ordering is good to a few ms. mono is only valid within one node.


No persistence, no "focus", no "active area". Those are consumers of this data, to be designed when it exists.


## 8. Build order


Each milestone is independently useful and testable on two devices.



|
# |
Milestone |
Done when |



|
M0 |
home_base skeleton, static manifest, two Nerves nodes + one plain-host node form a cluster via the Tailscale peer list |
Node.list/0 shows all three within 30 s of boot; survives reboot of any one; a node joins from outside the home LAN; adding a fourth needs only a manifest and the tag |


|
M1 |
Registry + leases + watchdog |
Home.Registry.list(kind: :audio_out) works from any node; lease acquire/release/monitor/renew behave; an :on_request mic turns off on release, on holder kill, and on timeout; PubSub events fire |


|
M2 |
Audio session mic → speaker over RTP |
Intercom from a laptop mic (:on_request) to a Nerves speaker; ≤ 150 ms latency; survives sink node restart (session tears down cleanly and the mic closes) |


|
M3 |
Shared secrets + HA area lookup |
Home.Secrets.put/2 on one node reaches all others and survives reboot; each node resolves its own area from HA with the shared token; refresh_area/0 picks up a move in HA |


|
M4 |
emerge scene forwarding |
An app on the laptop renders on a Nerves display with touch input flowing back; move/2 migrates it to a second display |


|
M5 |
Video session + emerge VideoSurface |
Camera on node A shown on display B; then pixel-forwarding fallback for a non-emerge app |


|
M6 |
Activity data |
Every capability kind above emits its events; Home.Activity.last/1,2 answers from any node within 100 ms of the event; a late-joining node has the snapshot |




Parallelizable: M3 doesn't depend on M2; M4 doesn't depend on M2–M3.


## 9. Open questions and deferred items


-  Tailscale on Nerves: which tailscaled build/package is used, how its state dir is persisted across firmware updates, and how auth keys are provisioned per device.

-  emerge: what is the current serialization format for the render tree, and does it already have diffing? Decide before M4. Answered in docs/EMERGE-FORWARDING.md: a binary format with Elixir-side diffing; forward the encoded bytes.

-  Confirm the device_id each device sends via homex/MQTT discovery identifiers is the one HA's device registry exposes, so the self-lookup in §3.3 matches.

-  Hardware H.264 on the specific RPi models in use — check rpicam-vid availability on the Nerves system in use.

- Deferred: ESP32/AtomVM devices (undecided); TLS distribution; encrypting the shared secret store at rest; multi-room audio sync; BLE bootstrap of credentials; dynamic capabilities (hot-plug USB mic); routing Zigbee/Thread commands across the cluster; hot code updates (separate effort).



