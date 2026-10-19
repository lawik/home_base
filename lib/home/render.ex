defmodule Home.Render do
  @moduledoc """
  Run an emerge app here and draw it on any node's display (§6.1 scene forwarding).

      {:ok, session} = Home.Render.show({MyApp.Viewport, app: MyApp.State}, on: {b, "disp0"})
      :ok = Home.Render.move(session, to: {c, "disp0"})

  The app is an ordinary `use Emerge` viewport, started here with its options plus
  `runtime: [adapter: Home.Render.Remote, adapter_opts: [session: pid]]`. It puts that
  in its config, which is the only change a viewport needs to render remotely:

      def mount(opts) do
        {:ok, %{app: opts[:app]}, %Emerge.Config{runtime: Keyword.get(opts, :runtime, [])}}
      end

  Emerge diffs the app's tree here as it would for a local window; the encoded tree and
  patches go to the display node's `Home.Render.Compositor`, which applies them to its
  own renderer. Element and input events come back to the viewport, so `Event`
  handlers (including `Solve.Lookup.event/2` targets) work unchanged.

  Showing needs a lease on the display (`:display` leases are shared; the latest
  session is drawn on top). The session holds it, renews it and stops the app if it
  is revoked or expires. Stopping the session (`stop/1`) stops the app.
  """

  @doc """
  Start `app_spec` (`{viewport_module, opts}`) on this node, drawn on `on:` (`{node, cap_id}`).
  Returns the session pid. Options: `:on` (required), `:purpose` (lease purpose),
  `:layer` (`:normal`, or `:overlay` to be drawn over the sessions below instead of
  hiding them; give the app a transparent background).
  """
  @spec show({module(), keyword()}, keyword()) :: {:ok, pid()} | {:error, term()}
  def show({module, opts} = _app_spec, show_opts) when is_atom(module) and is_list(opts) do
    target = Keyword.fetch!(show_opts, :on)

    DynamicSupervisor.start_child(
      Home.Render.Supervisor,
      {Home.Render.Session, {{module, opts}, target, show_opts}}
    )
  end

  @doc """
  Show video from a `:video_in` capability on a display (§6.3). `source` is a lease on
  the camera or its `{node, cap_id}`, which is then leased here (an `:on_request` camera
  turns on). The video fills the display, on top of what it showed.

  The pixels go over a `Home.Media.Session` (`codec: :h264`, RTP/UDP) straight from the
  camera's node to the display's; see `Home.Render.Video`. Returns the video session
  pid; `stop/1` stops it, and it stops by itself when either side goes away.

  Options: `:on` (required), `:purpose`, `:bitrate` (H.264 cap, default 3 Mbps),
  `:gop_size`, `:jitter`, `:input_to` (a pid that gets the display's input events).
  """
  @spec show_video(Home.Lease.t() | Home.Capability.ref(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def show_video(source, opts) do
    target = Keyword.fetch!(opts, :on)

    DynamicSupervisor.start_child(
      Home.Render.Supervisor,
      {Home.Render.Video, {source, target, opts}}
    )
  end

  @doc """
  Pixel forwarding (§6.2): run `app_spec` here, render it to frames on this node at the
  display's size, and stream them as H.264 to `on:`, where they fill the display. Input
  on the display comes back to the app.

  For an emerge viewport this is a drop-in for `show/2`: it gets the same `runtime:`
  option, whose adapter (`Home.Render.Pixels`) draws headless here. Any other app
  started with `module.start_link(opts)` can take part too: it finds the frame sink and
  size in `opts[:runtime][:adapter_opts]` (`:frames`, `:size`), sends the sink
  `{:emerge_skia_frame, %VideoInterop.Frame{}}` with binary RGBA frames, and receives
  input as `{:emerge_skia_event, event}`.

  Options as for `show_video/2`, plus `:fps` (30) and `:renderer` (an
  `Emerge.Config.Renderer`, default raster).
  """
  @spec show_pixels({module(), keyword()}, keyword()) :: {:ok, pid()} | {:error, term()}
  def show_pixels({module, app_opts} = app_spec, opts)
      when is_atom(module) and is_list(app_opts) do
    target = Keyword.fetch!(opts, :on)

    DynamicSupervisor.start_child(
      Home.Render.Supervisor,
      {Home.Render.Video, {app_spec, target, opts}}
    )
  end

  @doc "Draw the session's app on another display. The app keeps running."
  @spec move(pid(), keyword()) :: :ok | {:error, term()}
  def move(session, to: target), do: Home.Render.Session.move(session, target)

  @doc "Stop the session and its app; the display lease is released."
  @spec stop(pid()) :: :ok
  def stop(session), do: GenServer.stop(session, :normal)

  @doc "The display the session is drawn on."
  @spec target(pid()) :: Home.Capability.ref()
  def target(session), do: Home.Render.Session.target(session)
end
