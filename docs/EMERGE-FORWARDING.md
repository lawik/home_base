# Emerge scene forwarding (M4)

Answers the PLAN §9 open question ("what is emerge's serialization format for the
render tree, and does it already have diffing?") and records where §6.1 hooks in.
Read against emerge 0.5.0 (hex, = github `v0.5.0`, 9e19db8) and solve 0.3.1.

## What emerge does today

**Tree.** `Emerge.UI` builds plain `%Emerge.Engine.Element{type, key, id, attrs,
children, nearby}` structs in the viewport process. Event attrs hold
`{pid, message}` (`Event.on_press(:msg)` is `{self(), :msg}`; `Solve.Lookup.event/2`
returns a controller's `{pid, {:solve_event, name}}`).

**Diffing: yes, on the Elixir side.** Each viewport keeps an
`Emerge.Engine.DiffState` (retained `VNode` tree, `next_id`, event registry).
`Emerge.Engine.Reconcile` assigns stable numeric ids (keyed or positional siblings)
and produces patch ops: `set_attrs`, `set_children`, `set_nearby_mounts`,
`insert_subtree`, `insert_nearby_subtree`, `remove`.

**Serialization: a versioned binary ("EMRG", `Serialization` `@version 9`).**
`Emerge.Engine.encode_full/2` gives the full tree binary,
`Emerge.Engine.diff_state_update/2` the patch binary (`Emerge.Engine.Patch.encode/1`).
Handler pids and messages are not in the bytes; they stay in the diff state's event
registry keyed by element id. A counter text and colour change is a ~50-byte patch.

**Native side.** The Rustler NIF (`EmergeSkia.Native.renderer_upload/2`,
`renderer_patch/2`) takes only those bytes, keeps its own retained tree, and does
layout, text, assets and drawing (Skia; Wayland window, DRM/KMS, headless binary or
PRIME frames, macOS host). It never sees Elixir terms.

**Input path.** The native side hit-tests and sends
`{:emerge_skia_event, {element_id_bin, :press | :click | ...}}` (or
`{id, event, payload}`, key routes) to the renderer's input target; raw input
(`{:key, ...}`, `{:cursor_pos, ...}`, ...) is sent too when subscribed via
`config.input.events`. The viewport looks the id up in its diff state's event registry
and `send`s the registered `{pid, message}`; raw events go to `handle_input/2`.

**Assets.** Images are referenced by *logical path* (`"images/x.png"`, `~m"..."`,
atom), by absolute runtime path (`{:path, p}`, opt-in allowlist), or by preloaded id.
Logical paths are resolved natively against `asset_sources`, which emerge sets to the
single dir `:code.priv_dir(config.assets.otp_app)`. Fonts are registered in
`config.assets.fonts` and read from that priv dir when the renderer starts
(`EmergeSkia.load_font_file/5` can add more at runtime). So assets are referenced by
path, and the paths are relative to an OTP app's priv on the node that renders.

**Extension point.** `%Emerge.Config{runtime: [adapter: mod, adapter_opts: kw]}`
selects the renderer adapter (`Emerge.Runtime.Viewport.Renderer` behaviour: `start/2`,
`upload_tree/2`, `patch_tree/3`, `set_input_target/2`, `configure/3`, ...). The
viewport calls it with the Element tree and its diff state; the stock Skia adapter
encodes and calls the NIF. Custom adapters get the viewport pid as input target.

## Where to hook: between Elixir diffing and the native apply

Forward the **encoded bytes**, not Element trees, and not at the native layer:

* The app's viewport on A runs unchanged, with emerge's own diffing. A renderer
  adapter, `Home.Render.Remote`, does what the Skia adapter does (`encode_full`,
  `diff_state_update`) but hands the bytes to a `Home.Render.Session` on A, which
  sends them to `Home.Render.Compositor` on B. Wire traffic is emerge's own patch
  format: small and bursty, as §6.1 assumed.
* B applies the bytes to its local renderer (any backend). B needs no app code and no
  diff state.
* Events: B's native renderer reports element ids from A's id space; the compositor
  passes `{:emerge_skia_event, ev}` back through the session to A's viewport, whose
  diff state routes them to the registered pids (Solve controllers, etc.). Raw input
  goes the same way into `handle_input/2`. Nothing in the app changes.
* Move: the session keeps the latest assigned tree (`patch_tree` returns it), so it
  can `Serialization.encode_tree/1` it for a new display; A's diff state stays valid
  because ids don't change. Same for a compositor that restarts its renderer.

Rejected alternatives: shipping Element trees and diffing on B (full trees on the
wire every frame, and B would need the event registry: handler pids are fine, but
`wrap_payload/3` and key routes live in A's viewport module); forwarding at the
native/Rust layer (no gain, the bytes are the same, and it would need a Rust
transport).

The one thing the app does: put the `runtime:` option it is started with into its
config (`%Emerge.Config{runtime: Keyword.get(opts, :runtime, [])}`), since emerge
takes the adapter from the config `mount/1` returns.

## Assets

`Home.Render.Session` walks each tree for logical image sources (`image_src`,
`Background.image`) plus the app's `config.assets.fonts`, hashes the files from the
app's priv (sha256, cached per path), and asks the compositor which hashes it lacks
(`missing/3`, the §6.1 `{:assets_needed, [hash]}` round trip, only for paths not yet
sent to that display). Missing files are sent once over distribution; B writes them
to `<data_dir>/render/assets/<sha256>` and hard-links them under the session's
directory at their logical paths. That directory is B's renderer
`assets.sources`, so the tree's paths resolve unchanged and moving to another display
needs no tree rewrite. Fonts go before the renderer starts, images before the tree
that uses them (messages between two processes are ordered).

Runtime paths (`{:path, abs}`) and preloaded ids (`{:id, "img_<sha256>"}`, emerge's
canonical id for an image's bytes) only mean something on A. `Home.Render.Remote`
rewrites them, before emerge diffs the tree, to logical paths named by content hash
(`_home/<sha256>.<ext>`; `.svg` sniffed for ids), and the session sends those files by
hash like the rest (`Home.Render.Assets`). A runtime path's hash is cached by size,
mtime and inode; replacing the file shows the new image on the next render. Bytes for
ids are kept on A with `Home.Render.Assets.put_image/1`, which returns the id (emerge
0.5.0 has no public API for registering image bytes, so these ids are only usable
through forwarding for now). The app's own tree is untouched.

Assets of `asset_tcp_threshold` bytes or more (default 256 KiB, `config :home_base,
render: [...]`) go over a TCP side channel instead of one distribution message
(`Home.Render.AssetTransfer`): B listens on its render address (`:ip`, default the
media IP; `:asset_ports`, default ephemeral) for one connection with a one-time token,
checks size and sha256 while writing to its cache, and acks; A then sends a `link`
message, which keeps the ordering "assets before the tree that uses them".

## Emerge changes (prototyped in `/root/workspace/emerge-home`, patch in `emerge-scene-forwarding.patch`)

Both are small, Elixir-only (no NIF change, so the 0.5.0 precompiled NIF is used),
and upstream-able:

1. **`EmergeSkia.upload_tree_binary/2` and `EmergeSkia.patch_tree_binary/2`**: public
   apply of already-encoded bytes. The transport functions exist
   (`EmergeSkia.Transport.*.upload_tree/2`, `patch_tree/2`) but are `@moduledoc
   false`; the public API only takes Element trees and does the diffing itself.
   Encoding elsewhere (another process or node) needs this.
2. **`Emerge.Config.Assets.sources`**: extra directories searched for logical asset
   paths (images and fonts) after the `otp_app` priv dir. The NIF already takes a
   list of sources; emerge always passed `[priv_dir]`. Without it, a renderer can only
   resolve logical paths inside an OTP app's priv, so B could not draw A's assets
   without rewriting A's tree per display.

3. **`EmergeSkia.inject_input/2`** (branch `home-m8-forwarding`, commit `ada4c6d`;
   **needs a native rebuild**): feed raw input (the shapes the renderer reports:
   `{:cursor_button, {button, action, mods, {x, y}}}`, `{:key, ...}`, ...) into a
   running renderer's event actor, as if its backend had produced it. Hit-testing,
   element events, focus, text editing and scrolling then run as for native input,
   with any backend including headless. Used for pixel forwarding (the display's input
   goes into the app's headless renderer on A, so `on_press` etc. work) and for input
   drivers that are not the renderer's own backend (`Home.Render.Compositor.inject/2`).
   About 30 lines of Rust plus the transport plumbing; the macOS host returns
   `{:error, :unsupported}`.

Building the NIF from source: put cargo on `PATH` (rustup) and compile with
`EMERGE_SKIA_BUILD=true` (rustler is a build-only dep of home_base for that). The
first build takes a while (skia-bindings); the result is copied to emerge's
`priv/native/emerge_skia.so`. Tests that need injection are tagged `:emerge_inject` and
are excluded automatically when the loaded NIF lacks it (precompiled 0.5.0).

The fork is a copy of the hex 0.5.0 package source plus the patch, used as a path dep
(`EMERGE_PATH`, default `/root/workspace/emerge-home`). Once upstream has these,
switch back to `{:emerge, "~> 0.x"}`.

## Layering

`:display` leases are shared. The compositor stacks sessions, latest on top. An
ordinary session hides the ones below it: only it is drawn, and its bytes go to the
renderer untouched (a session that comes back on top gets a fresh renderer with its
fonts/assets and sends its full tree). A session shown with `layer: :overlay` is drawn
over the sessions below it, down to the first ordinary one.

Emerge draws one tree per renderer, so overlays are composed on the display node,
in Elixir, from the bytes the sessions already send (`Home.Render.Layers`), with no
emerge change:

* each session gets a layer number; its full tree is decoded
  (`Emerge.Engine.Serialization.decode/1`) and its patches decoded
  (`Emerge.Engine.Patch.decode/1`), every id is moved to `layer <<< 48 ||| id`, and the
  result re-encoded. No diffing and no retained copy of the trees on B: patches are
  translated op by op;
* the layers hang in a chain of empty full-size wrappers: wrapper `i` has layer `i`
  as its `behind` nearby and the next wrapper (the last: the top layer) as its child.
  `behind` paints under the host's children, so the order is bottom to top. (Mounting
  layers `in_front` of one root draws the same, but emerge makes `in_front` nearby
  roots block pointer input to everything under their box, its modal semantics, so a
  full-size overlay would swallow all presses);
* element events come back with composed ids: the high bits give the layer, hence the
  session, which gets the event with its own id; raw input goes to the top session
  (or the `:input` holder);
* image and font paths are prefixed with the layer number, and the renderer's single
  asset source is the directory holding the sessions' asset directories, which are
  named by layer.

Any change of the visible set restarts the renderer and asks the visible sessions for
full trees. Cost on B while composed: decode and re-encode of each patch (the plain
case stays a byte passthrough). Not done: per-layer opacity or placement (an overlay
is full-size and positions its content itself), and video frames of two layers with
the same video target name collide.

## Not done / limits

* Outputs: tests use headless displays, except `test/render_drm_test.exs` (tag `:drm`,
  excluded by default): B's display is `%Emerge.Config.DRM{card: "/dev/dri/card0"}`
  with raster presentation (CPU dumb buffers; in the VM, bochs-drm). The test reads
  what the CRTC scans out with plain DRM ioctls (`test/support/drm/drmgrab.c`) and taps
  a uinput touchscreen (`utouch.c`) that emerge's bundled libinput picks up, so input
  goes evdev, libinput, B's hit-testing, A's Solve controller. Needs root, a free card,
  and a NIF built with a DRM backend:
  `HOME_EMERGE_BACKENDS='[wayland: [:opengl], drm: [:raster], headless: [:opengl]]'
  EMERGE_SKIA_BUILD=true mix test --only drm test/render_drm_test.exs` (use a separate
  `MIX_BUILD_PATH`; the built NIF lands in emerge's `priv/` and also serves the other
  backends). Other tests drive input as already-hit-tested events
  (`Compositor.input/2`) or, with a source-built NIF, as raw input into B's renderer
  (`Compositor.inject/2`). The Wayland window backend is not exercised (no compositor
  in the VM).
* Native retained UI state: scroll positions and focus are carried across `move/2`
  and a re-shown session (`Home.Render.Retained`): `Home.Render.Remote` adds
  `on_scroll`/`on_focus`/`on_blur` handlers where the app has none, the session
  records the events as they pass, and the full tree for a new renderer carries them
  as emerge's one-shot `scroll_x/y` fractions and `focus_on_mount`. No emerge change.
  The caret/selection in a text input is not kept (emerge does not report it; a
  restored focus puts the caret at the start): that would need a native
  "export/import runtime state" call.
* `:input` capability: a display declares its input devices as an `:input`
  capability (`{Home.Adapters.Display, input: "input0"}` plus
  `%{id: "input0", kind: :input, adapter: Home.Adapters.Input}`); the display adapter
  registers its compositor as that capability's device. `:input` leases are
  exclusive. Render, pixel and video sessions lease it next to the display
  (`Home.Render.InputLease`, retrying every second while someone else holds it) and
  route it to themselves (`Compositor.route_input/3`); any other process can hold it
  and route it to itself. With an `:input` capability, input goes only to the routed
  holder (element events only if that is the session drawn); without one, to the
  session on top as before. A revoked input lease takes input away from a session,
  not the display.
* §6.2 pixel forwarding and §6.3 video surfaces: see `VIDEO.md` (M5).
