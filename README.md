# home_base

A home cluster of equals. Every device in the house (Nerves boxes, laptops, a server)
runs the same `:home_base` OTP application; they form one Erlang cluster and lend each
other hardware: microphones, speakers, cameras, displays, radios, sensors.

- **Capabilities** are described by a static per-device manifest and found cluster-wide
  through `:pg` (`Home.Registry`).
- **Leases** are the only way to use a capability (`Home.Lease`). Capture hardware on a
  laptop can be `:on_request`: off until a lease starts it, off again when the lease
  ends, when its holder dies, when a safety timeout runs out, or on `revoke_all/0`.
- **Media** goes from any source to any sinks over RTP/UDP with Membrane
  (`Home.Media.Session`: Opus audio, H.264 video).
- **Rendering**: any node runs an [emerge](https://hex.pm/packages/emerge) app and draws it
  on any node's display, moves it between displays, or shows a camera on one
  (`Home.Render`).
- **Secrets** (HA token and the like) replicate to every node (`Home.Secrets`); each
  node's room comes from Home Assistant; **activity** (when was each capability last
  used, and how) is recorded cluster-wide (`Home.Activity`).
- A **lease indicator** app shows what is on and who holds it, with a "Revoke all"
  button (`Home.Indicator`).

There is no hub and no singleton. The design is in [docs/PLAN.md](docs/PLAN.md).

## Configuration

`:home_base` reads its app env (`config :home_base, ...`); see `Home` for details.

```elixir
config :home_base,
  device_id: "kitchen",
  capabilities: [
    %{id: "mic0", kind: :audio_in, adapter: Home.Adapters.Audio.PortAudioIn},
    %{id: "spk0", kind: :audio_out, adapter: Home.Adapters.Audio.PortAudioOut},
    %{id: "disp0", kind: :display, meta: %{w: 1024, h: 600, touch: true},
      adapter: {Home.Adapters.Display, output: %Emerge.Config.DRM{}}}
  ],
  cluster: [backend: Home.Cluster.Tailscale],
  data_dir: "/data/home"
```

| Option | Meaning |
| --- | --- |
| `:device_id` | Stable id of this device (also its id in Home Assistant). Default: the hostname. |
| `:capabilities` | List of `Home.Capability` structs or maps (fields below). |
| `:manifest` | Instead of `:device_id`/`:capabilities`: a keyword with both, or `{:file, path}` to an `.exs` file returning one (see `examples/`). |
| `:cluster` | `[backend: module \| {module, opts}, interval: ms]`. How peers are found; re-queried every `interval` (default 30 s) and on every nodedown. Default backend `Home.Cluster.Epmd`. |
| `:data_dir` | Where secrets, the area and rendered assets persist. Default `<tmp>/home_base-<node>`. |
| `:media` | `[ip: ip_tuple, ports: first..last]`: the address and UDP range this node receives media on. Default `{127, 0, 0, 1}`, `50000..50099`. |
| `:video` | `[decoders: [...], software: true]`: what this node's displays decode H.264 with. `decoders` are its hardware decoders, each a `Home.Media.Video.Format` or its fields: `element` (a Membrane filter from Annex B access units to `%VideoInterop.Frame{}`s or RGB/RGBA, e.g. `Membrane.V4L2.H264.Decoder` for the Venus hardware decoder on a Fairphone 3), `name`, `profiles`, `max_level`, `max_size`, `max_fps`. FFmpeg's software decoder comes after them unless `software: false`. Video sessions negotiate a stream these take, in hardware where there is any (see `Home.Media.Video`). The older `decoder: module` is one hardware decoder with no known limits. |
| `:ha` | `[area_refresh: ms, timeout: ms, lookup_timeout: ms]`: Home Assistant area lookup every 3 h, 10 s per network step, 3 × `timeout` for a whole lookup. HA URL and token come from `Home.Secrets` (`:ha_url`, `:ha_token`). |
| `:watchdog_interval` | How often (ms) the lease watchdog expires old leases. Default 1000. |
| `:activity` | `[ring: n]`: recent events kept per capability and kind. Default 64. |

### Cluster backends

| Backend | Peers |
| --- | --- |
| `Home.Cluster.Tailscale` | Online tailnet devices tagged `tag:homecluster`, as `home@<tailscale ip>`. Options `:tag`, `:basename`, `:cmd`. |
| `{Home.Cluster.Static, nodes: [:"home@10.0.0.2", ...]}` | A fixed list. |
| `Home.Cluster.Epmd` | Other BEAMs in the local epmd whose names share this node's prefix (up to the first `-` or digit; option `:prefix`). For several nodes on one machine. |

The node itself must already be distributed (`--name`/`-name`, shared cookie);
`home_base` only connects and keeps connected.

### Capability fields

| Field | Meaning |
| --- | --- |
| `id` | Unique on the node, e.g. `"mic0"`. Cluster-wide a capability is `{node, id}`. |
| `kind` | `:audio_in`, `:audio_out`, `:video_in`, `:display`, `:input`, `:zigbee`, `:thread`, `:sensor`, `:presence`. |
| `availability` | `:always` (default; hardware on at boot), `:on_request` (on only while leased), `:off` (not vended). |
| `adapter` | `module` or `{module, opts}` implementing `Home.Adapter`; opts are merged into `meta`. |
| `max_age` | Lease safety timeout in ms, counted from the last renew. Default 10 min for `:audio_in`/`:video_in`, 60 min otherwise. |
| `meta` | Adapter settings and hints (`channels`, `rate`, `w`, `h`, `fps`, `device`, ...). |

Adapters: `Home.Adapters.Audio.PortAudioIn` / `PortAudioOut` (real sound cards),
`Home.Adapters.Video.Camera` (V4L2/AVFoundation), `Home.Adapters.Display` (emerge:
window, DRM or headless), the synthetic `Home.Adapters.Audio.SynthMic`,
`Home.Adapters.Audio.CaptureSpeaker` and `Home.Adapters.Video.SynthCamera` (for tests and
demos), and `Home.Adapters.Null` (announce only).

`:audio_out` and `:display` leases are shared (the speaker mixes, the display draws the
newest session on top); the other kinds take one lease at a time.

## Using it

Capabilities across the cluster:

```elixir
Home.Registry.list()                         # everything
Home.Registry.list(kind: :audio_in)          # filters: kind:, node:, area:
#=> [%{ref: {:"home@100.64.0.3", "mic0"}, cap: %Home.Capability{...}, status: :idle,
#      hardware: :off, area: "Kitchen", device_id: "kitchen", leases: 0, held_by: []}]
Home.Registry.area()                         # this node's room, from Home Assistant
```

Leases (the holder is the calling process unless `for: pid`; it is released when the
holder exits):

```elixir
{:ok, lease} = Home.Lease.acquire({laptop, "mic0"}, purpose: "intercom")
:ok = Home.Lease.renew(lease)       # before the capability's max_age runs out
:ok = Home.Lease.release(lease)
Home.Lease.revoke_all()             # on this node: drop every lease, on-request hardware off
```

An intercom: a mic on one node to a speaker on another. The session runs on the
caller's node, takes over the leases and renews them:

```elixir
{:ok, mic} = Home.Lease.acquire({laptop, "mic0"}, purpose: "intercom")
{:ok, spk} = Home.Lease.acquire({kitchen, "spk0"}, purpose: "intercom")
{:ok, session} = Home.Media.Session.start(source: mic, sink: spk)   # codec: :opus
Home.Media.Session.stop(session)
```

Apps on displays. The app is an ordinary `use Emerge` viewport that puts
`opts[:runtime]` in its `Emerge.Config` (see `Home.Render`):

```elixir
{:ok, app} = Home.Render.show({MyApp.Viewport, []}, on: {kitchen, "disp0"})
:ok = Home.Render.move(app, to: {laptop, "disp0"})          # the app keeps running
{:ok, video} = Home.Render.show_video({laptop, "cam0"}, on: {kitchen, "disp0"})
{:ok, pixels} = Home.Render.show_pixels({MyApp.Viewport, []}, on: {tv, "disp0"})  # H.264 instead of scene forwarding
Home.Render.stop(video)
```

The lease indicator, shown once or kept up by a supervised process:

```elixir
Home.Render.show({Home.Indicator.Viewport, node: node()}, on: {node(), "disp0"})
children = [{Home.Indicator, on: {node(), "disp0"}}]
```

Secrets, the same on every node:

```elixir
Home.Secrets.put(:ha_url, "http://homeassistant.local:8123")
Home.Secrets.put(:ha_token, "...")
Home.Secrets.get(:ha_token)
```

Activity:

```elixir
Home.Activity.subscribe(:audio_in)            # or a {node, id}; get {:activity, event}
Home.Activity.last({kitchen, "mic0"}, :lease)
Home.Activity.since({kitchen, "disp0"}, :input, 60_000)
Home.Activity.emit(cap, :input, :touch, %{})  # from an adapter
```

## Try it: three nodes on one machine

`mix home.node MANIFEST --name NAME` starts a named node with a manifest (see
`mix help home.node` for `--cookie`, `--backend epmd|static`, `--peers`,
`--media-ports`, `--data-dir`, `--require`). `scripts/node.sh NAME MANIFEST` runs it
under `iex` with `examples/demo.exs` loaded, which has a few helpers (`Demo.caps/0`,
`Demo.node!/1`, `Demo.snapshot/2`) and a small app (`Demo.Hello`).

The manifests in `examples/`:

- `kitchen.exs`: an always-on (synthetic) mic, a speaker that records to
  `<tmp>/home-kitchen-spk0.pcm`, a display.
- `laptop.exs`: an on-request (synthetic) mic and camera, a display.
- `server.exs`: headless, no hardware; it drives the others.

Displays are headless (render to memory; `Demo.snapshot/2` saves them as PNG). With
`HOME_DISPLAY=window` in a Wayland session they open as windows instead.

Run `mix deps.get && mix compile` once, then in three terminals:

```sh
scripts/node.sh home-kitchen examples/kitchen.exs
scripts/node.sh home-laptop  examples/laptop.exs
scripts/node.sh home-server  examples/server.exs
```

Nodes named `home-*` find each other through epmd within a couple of seconds. (With
`--backend static --peers home-kitchen@127.0.0.1,...` they connect to a fixed list
instead.) On the server:

```elixir
iex> Demo.caps()
home-kitchen/disp0   display    always      hw on   idle
home-kitchen/mic0    audio_in   always      hw on   idle
home-kitchen/spk0    audio_out  always      hw on   idle
home-laptop/cam0     video_in   on_request  hw off  idle
home-laptop/disp0    display    always      hw on   idle
home-laptop/mic0     audio_in   on_request  hw off  idle

iex> kitchen = Demo.node!(:kitchen); laptop = Demo.node!(:laptop)
```

An intercom from the laptop's mic to the kitchen speaker. The laptop mic turns on:

```elixir
iex> {:ok, mic} = Home.Lease.acquire({laptop, "mic0"}, purpose: "intercom")
iex> {:ok, spk} = Home.Lease.acquire({kitchen, "spk0"}, purpose: "intercom")
iex> {:ok, intercom} = Home.Media.Session.start(source: mic, sink: spk)
iex> Demo.caps()
...
home-kitchen/spk0    audio_out  always      hw on   leased  home-server: intercom
home-laptop/mic0     audio_in   on_request  hw on   leased  home-server: intercom
```

The kitchen speaker's recording grows (`ls -l /tmp/home-kitchen-spk0.pcm`).

An app running on the server, drawn in the kitchen, then moved to the laptop:

```elixir
iex> {:ok, hello} = Home.Render.show({Demo.Hello, title: "Hello, kitchen"}, on: {kitchen, "disp0"})
iex> Demo.snapshot({kitchen, "disp0"}, "/tmp/kitchen.png")
iex> Home.Render.move(hello, to: {laptop, "disp0"})
iex> Demo.snapshot({laptop, "disp0"}, "/tmp/laptop.png")
```

The laptop camera on the kitchen display (the camera turns on; it goes off again when
the video stops):

```elixir
iex> {:ok, video} = Home.Render.show_video({laptop, "cam0"}, on: {kitchen, "disp0"})
iex> Demo.snapshot({kitchen, "disp0"}, "/tmp/camera.png")
iex> Home.Render.stop(video)
```

On the laptop, show its lease indicator on the kitchen display, then revoke everything
the laptop lends out. With `HOME_DISPLAY=window` you can press "Revoke all" instead;
the button calls `Home.Lease.revoke_all/0` on the node the indicator runs on, here the
laptop:

```elixir
iex(home-laptop)> {:ok, _} = Home.Render.show({Home.Indicator.Viewport, node: node()}, on: {Demo.node!(:kitchen), "disp0"})
iex(home-laptop)> Home.Lease.revoke_all()
```

The intercom stops, the laptop mic is off again, and `hello`, which held the laptop's
display, stops too. The indicator (its lease is on the kitchen display) now says
"Nothing in use". Back on the server:

```elixir
iex> Demo.caps()
home-kitchen/disp0   display    always      hw on   leased  home-laptop: render
home-kitchen/mic0    audio_in   always      hw on   idle
home-kitchen/spk0    audio_out  always      hw on   idle
home-laptop/cam0     video_in   on_request  hw off  idle
home-laptop/disp0    display    always      hw on   idle
home-laptop/mic0     audio_in   on_request  hw off  idle
iex> {Process.alive?(intercom), Process.alive?(hello)}
{false, false}
```

## Tests

```sh
mix test
```

Tests start real multi-node clusters on OTP `:peer` nodes (helpers in `test/support`).
Tests that need a sound card (`:portaudio`) or a V4L2 camera (`:v4l2`) are excluded by
default; run them with `mix test --include portaudio` / `--include v4l2`.
