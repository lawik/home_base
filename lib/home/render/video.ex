defmodule Home.Render.Video do
  @moduledoc """
  A video surface on a (possibly remote) display: a `:video_in` capability (§6.3) or an
  app rendered to pixels on this node (§6.2), shown full-screen on the display.

  To the display's `Home.Render.Compositor` this process is a render session like any
  other (it stacks, latest on top): its tree is one `Emerge.UI.video/2` element filling
  the display. The pixels arrive separately, through a `Home.Media.Session` with
  `codec: :h264` from the source to the display, whose sink pipeline on the display node
  hands decoded frames to the compositor for that element. The media session holds the
  camera and display leases; when it ends (either side gone, a lease revoked or expired)
  this process stops, and when this process stops the media session does too.

  Input on the display comes back here, as for scene forwarding. For an emerge pixel
  app it is injected into the app's headless renderer, which hit-tests it against the
  app's tree (element events work); a non-emerge app (or `:input_to`) gets it as
  `{:emerge_skia_event, event}`.

  Started by `Home.Render.show_video/2` and `Home.Render.show_pixels/2`.
  """

  use GenServer, restart: :temporary

  alias Home.Lease
  alias Home.Render.Compositor

  @target :home_video

  defstruct [
    :display,
    :compositor,
    :media,
    :app,
    :input_target,
    :renderer,
    :tree,
    :input,
    view: %{}
  ]

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @doc false
  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}

  @doc "The media session carrying the pixels."
  def media(video), do: GenServer.call(video, :media)

  ## Server

  @impl true
  def init({source, target, opts}) do
    Process.flag(:trap_exit, true)
    purpose = Keyword.get(opts, :purpose, "video")

    with {:ok, display} <- acquire_display(target, purpose),
         state = surface(%__MODULE__{display: display, compositor: display.endpoint}, source),
         :ok <- attach(state),
         state = take_input(state, purpose),
         {:ok, src} <- media_source(source, purpose, opts) |> or_cleanup(state),
         {:ok, state} <- start_media(state, src, display, opts),
         {:ok, state} <- start_app(state, source, opts) do
      {:ok, state}
    else
      {:error, reason, state} ->
        cleanup(state)
        {:stop, reason}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:target, _from, state), do: {:reply, state.display.cap, state}
  def handle_call(:media, _from, state), do: {:reply, state.media, state}

  def handle_call({:move, target}, _from, %{display: %{cap: target}} = state),
    do: {:reply, :ok, state}

  # `Home.Render.move/2`: the new display joins the media session as a second sink (the
  # source sends it a keyframe), then the old one leaves it. The source keeps running.
  def handle_call({:move, target}, from, state) do
    purpose = state.display.purpose || "video"

    with {:ok, display} <- acquire_display(target, purpose),
         new = %{state | display: display, compositor: display.endpoint},
         :ok <- attach_or_release(new),
         :ok <- add_sink(new) do
      _ = Home.Media.Session.remove_sink(state.media, state.display.cap)
      # The move is done once the new display has the video; the old compositor can
      # take its time to let go.
      GenServer.reply(from, :ok)
      safe(fn -> Compositor.detach(state.compositor, self()) end)
      {:noreply, new}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:home_render_input, comp, event}, %{compositor: comp} = state) do
    injected? = state.renderer != nil and inject(state.renderer, event)

    if not injected? and state.input_target,
      do: send(state.input_target, {:emerge_skia_event, event})

    {:noreply, state}
  end

  # The pixel app's headless renderer (`Home.Render.Pixels`), the display's input goes into.
  def handle_info({:home_pixels_renderer, renderer}, state),
    do: {:noreply, %{state | renderer: renderer}}

  def handle_info({:home_render_resync, comp}, %{compositor: comp} = state) do
    Compositor.upload(comp, self(), state.tree)
    {:noreply, state}
  end

  # The pixel app's raw input subscriptions become the display renderer's.
  def handle_info({:home_pixels_input, input}, state) do
    state = %{state | view: %{state.view | input: input}}
    Compositor.configure(state.compositor, self(), state.view)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{media: pid} = state),
    do: {:stop, {:shutdown, {:media, reason}}, %{state | media: nil}}

  def handle_info({:EXIT, pid, :normal}, %{app: pid} = state),
    do: {:stop, :normal, %{state | app: nil}}

  def handle_info({:EXIT, pid, reason}, %{app: pid} = state),
    do: {:stop, {:shutdown, {:app, reason}}, %{state | app: nil}}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  ## Setup

  defp or_cleanup({:error, reason}, state), do: {:error, reason, state}
  defp or_cleanup(ok, _state), do: ok

  defp acquire_display(target, purpose) do
    case Lease.acquire(target, for: self(), purpose: purpose) do
      {:ok, %Lease{endpoint: comp} = lease} when is_pid(comp) ->
        {:ok, lease}

      {:ok, lease} ->
        Lease.release(lease)
        {:error, :not_a_display}

      error ->
        error
    end
  end

  # One video element filling the display. A pixel app's input subscriptions arrive
  # when its renderer starts; until then (and for a camera) none.
  defp surface(state, source) do
    import Emerge.UI.Size

    tree =
      Emerge.UI.el(
        [
          width(fill()),
          height(fill()),
          Emerge.UI.Background.color(Emerge.UI.Color.color_rgb(0, 0, 0))
        ],
        Emerge.UI.video([width(fill()), height(fill())], @target)
      )

    {bin, _diff_state, _assigned} =
      Emerge.Engine.encode_full(Emerge.Engine.diff_state_new(), tree)

    input = if pixels?(source), do: all_input(), else: %Emerge.Config.Input{}
    %{state | tree: bin, view: %{fonts: [], input: input}}
  end

  defp pixels?({module, opts}), do: is_atom(module) and is_list(opts)
  defp pixels?(_camera), do: false

  defp all_input, do: %Emerge.Config.Input{events: Emerge.Config.Input.all_events()}

  defp attach(state) do
    case safe(fn -> Compositor.attach(state.compositor, self(), state.view) end) do
      :ok ->
        Compositor.upload(state.compositor, self(), state.tree)
        :ok

      error ->
        {:error, {:attach_failed, error}, state}
    end
  end

  defp attach_or_release(state) do
    case attach(state) do
      :ok ->
        :ok

      {:error, reason, _state} ->
        Lease.release(state.display)
        {:error, reason}
    end
  end

  defp add_sink(state) do
    case Home.Media.Session.add_sink(state.media, state.display) do
      :ok ->
        :ok

      error ->
        safe(fn -> Compositor.detach(state.compositor, self()) end)
        Lease.release(state.display)
        error
    end
  catch
    :exit, reason -> {:error, {:media_down, reason}}
  end

  # A camera lease (or its capability, leased here), or an app to render here.
  defp media_source(%Lease{} = lease, _purpose, _opts), do: {:ok, lease}

  defp media_source({node, id} = cap, purpose, _opts) when is_atom(node) and is_binary(id),
    do: Lease.acquire(cap, for: self(), purpose: purpose)

  defp media_source({module, app_opts}, _purpose, opts)
       when is_atom(module) and is_list(app_opts),
       do: {:ok, %Home.Media.FrameSource{notify: self(), fps: Keyword.get(opts, :fps, 30)}}

  defp start_media(state, source, display, opts) do
    media_opts =
      opts
      |> Keyword.take([
        :bitrate,
        :gop_size,
        :jitter,
        :renew_every,
        :feedback,
        :route,
        :size,
        :fps,
        :decoder
      ])
      |> Keyword.merge(
        source: source,
        sink: display,
        codec: :h264,
        surface: {self(), @target},
        owner: self()
      )

    case Home.Media.Session.start(media_opts) do
      {:ok, media} ->
        Process.monitor(media)
        {:ok, %{state | media: media}}

      {:error, reason} ->
        if match?(%Lease{}, source) and source.holder == self(),
          do: Lease.release(source)

        {:error, {:media_failed, reason}, state}
    end
  end

  defp start_app(state, {module, app_opts}, opts) when is_atom(module) and is_list(app_opts) do
    receive do
      {:home_frame_source, frames} ->
        runtime = [
          adapter: Home.Render.Pixels,
          adapter_opts: [
            session: self(),
            frames: frames,
            size: display_size(state.display),
            renderer: Keyword.get(opts, :renderer, %Emerge.Config.Renderer{api: :raster})
          ]
        ]

        case module.start_link(Keyword.put(app_opts, :runtime, runtime)) do
          {:ok, app} -> {:ok, %{state | app: app, input_target: app}}
          {:error, reason} -> {:error, {:app_failed, reason}, state}
        end
    after
      5_000 -> {:error, :no_frame_source, state}
    end
  end

  defp start_app(state, _camera, opts), do: {:ok, %{state | input_target: opts[:input_to]}}

  defp display_size(lease) do
    case safe(fn -> Home.Capability.Server.info(lease.server) end) do
      %{cap: %{meta: meta}} -> {Map.get(meta, :w, 800), Map.get(meta, :h, 600)}
      _ -> {800, 600}
    end
  end

  # The display's :input capability, if it has one (`Home.Render.InputLease`).
  defp take_input(state, purpose) do
    case Home.Render.InputLease.start_link(state.compositor, self(), purpose) do
      {:ok, pid} -> %{state | input: pid}
      _ -> state
    end
  end

  defp cleanup(state) do
    # The app first, so it stops rendering; the media session releases the leases.
    if state.app, do: Process.exit(state.app, :shutdown)
    Home.Render.InputLease.stop(state.input)
    if state.media, do: Home.Media.Session.stop(state.media)
    safe(fn -> Compositor.detach(state.compositor, self()) end)
    Lease.release(state.display)
  end

  # True if the renderer took it (or rejected its shape, e.g. an element event of the
  # display's own tree); false if this emerge has no input injection (older NIF).
  defp inject(renderer, event) do
    _ = EmergeSkia.inject_input(renderer, event)
    true
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> false
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
