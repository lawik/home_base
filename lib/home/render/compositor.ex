defmodule Home.Render.Compositor do
  @moduledoc """
  Draws remote render sessions on this node's display with the local emerge renderer.

  Started by `Home.Adapters.Display`; it is the display capability's lease endpoint.
  A `Home.Render.Session` on another node sends the assets its app uses, attaches, then
  sends the encoded tree (`EmergeSkia.upload_tree_binary/2`) and patches
  (`EmergeSkia.patch_tree_binary/2`). The session keeps emerge's diff state; this
  process only applies bytes. Native input goes back to the session that is shown.

  Sessions stack in attach order, latest on top. Only the top one is drawn: emerge has
  one tree per renderer, so a session that becomes top gets a fresh renderer (with its
  own fonts and asset directory) and is asked for a full tree.

  Assets are cached on disk under `<data_dir>/render/assets/<sha256>` (large ones arrive
  over TCP, `Home.Render.AssetTransfer`); each session
  gets a directory of its logical paths linked into that cache, which is the
  renderer's `assets.sources`.
  """

  use GenServer
  require Logger

  alias Home.Activity

  defstruct [
    :cap,
    :config,
    :dir,
    :renderer,
    :frame,
    :input_cap,
    :input_route,
    sessions: %{},
    stack: [],
    synced?: false
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  ## Session side

  @doc "Put `session` on top. Its fonts must already be sent with `put_asset/5`."
  def attach(comp, session, view), do: GenServer.call(comp, {:attach, session, view}, 15_000)

  def detach(comp, session), do: GenServer.call(comp, {:detach, session})

  @doc "Of `[{logical_path, hash}]`, the hashes this node lacks. Known ones are linked in."
  def missing(comp, session, entries), do: GenServer.call(comp, {:missing, session, entries})

  def put_asset(comp, session, logical, hash, data),
    do: send(comp, {:asset, session, logical, hash, data})

  @doc """
  Get ready to receive a large asset over TCP (`Home.Render.AssetTransfer`). Returns
  `{:ok, {ip, port, token}}`; once the transfer is acked, the session sends `link/4`.
  """
  def receive_asset(comp, session, hash, size),
    do: GenServer.call(comp, {:receive_asset, session, hash, size})

  @doc "Link an asset already in the cache (received over TCP) at `logical` for `session`."
  def link(comp, session, logical, hash), do: send(comp, {:link, session, logical, hash})

  def upload(comp, session, bin), do: send(comp, {:upload, session, bin})
  def patch(comp, session, bin), do: send(comp, {:patch, session, bin})
  def configure(comp, session, view), do: send(comp, {:configure, session, view})

  @doc """
  Show `frame` (`%VideoInterop.Frame{}`) in the video element `target` of `session`'s
  tree (`Emerge.UI.video/2`), if that session is the one drawn. Sent by
  `Home.Media.VideoSink`.
  """
  def video_frame(comp, session, target, frame),
    do: send(comp, {:video_frame, session, target, frame})

  ## Input (`Home.Adapters.Input`)

  @doc "The `:input` capability of this display (`{node, id}`), or nil if it has none."
  def input_cap(comp), do: GenServer.call(comp, :input_cap)

  @doc """
  Send this display's input to `target` (a render session, or any process: it gets
  `{:home_render_input, comp, event}`), as the holder of `lease` on its `:input`
  capability. Lasts until `unroute_input/2`, or the lease holder exits. Raw input goes
  to `target`; element events only when `target` is the session drawn (they carry ids
  of the drawn tree).
  """
  def route_input(comp, %Home.Lease{} = lease, target),
    do: GenServer.call(comp, {:route_input, lease, target})

  def unroute_input(comp, %Home.Lease{ref: ref}), do: GenServer.call(comp, {:unroute_input, ref})

  ## Display side

  @doc """
  Feed an event as if the renderer had reported it (an element event such as
  `{element_id, :press}`, or raw input it is subscribed to). Skips hit-testing.
  """
  def input(comp, event) do
    send(comp, {:emerge_skia_event, event})
    :ok
  end

  @doc """
  Feed raw input into the display's renderer, as if its own input device had produced
  it (`EmergeSkia.inject_input/2` shapes: `{:cursor_button, {button, action, mods,
  {x, y}}}`, `{:key, ...}`, ...). The renderer hit-tests it against the shown tree,
  so element events come out as from a real pointer or keyboard. For an input driver
  that is not the renderer's own backend, and for tests.
  """
  def inject(comp, event), do: GenServer.call(comp, {:inject, event})

  @doc "The session drawn now, or nil."
  def shown(comp), do: GenServer.call(comp, :shown)

  @doc "The latest frame of a headless output (`%VideoInterop.Frame{}`), or nil."
  def frame(comp), do: GenServer.call(comp, :frame)

  @doc "Pixels of the latest presented frame, see `EmergeSkia.render_to_pixels/2`."
  def capture(comp, opts), do: GenServer.call(comp, {:capture, opts})

  ## Server

  @impl true
  def init(opts) do
    dir = Path.join(Home.data_dir(), "render")
    File.mkdir_p!(Path.join(dir, "assets"))
    File.rm_rf!(Path.join(dir, "sessions"))

    {:ok,
     %__MODULE__{
       cap: Keyword.fetch!(opts, :cap),
       config: Keyword.fetch!(opts, :config),
       input_cap: Keyword.get(opts, :input),
       dir: dir
     }}
  end

  @impl true
  def handle_call({:attach, pid, view}, _from, state) do
    {_entry, state} = entry(state, pid)
    state = put_in(state.sessions[pid].view, view)
    if pid not in state.stack, do: emit(state, :session_started, pid)
    state = %{state | stack: [pid | List.delete(state.stack, pid)]}
    {:reply, :ok, show_top(state, false)}
  end

  def handle_call({:detach, pid}, _from, state), do: {:reply, :ok, drop(state, pid)}

  def handle_call({:missing, pid, entries}, _from, state) do
    {entry, state} = entry(state, pid)

    {present, absent} =
      entries
      |> Enum.filter(fn {logical, _} -> safe_logical?(logical) end)
      |> Enum.split_with(fn {_, hash} -> File.regular?(cache_path(state, hash)) end)

    Enum.each(present, fn {logical, hash} -> link_file(state, entry, logical, hash) end)
    {:reply, absent |> Enum.map(&elem(&1, 1)) |> Enum.uniq(), state}
  end

  def handle_call({:receive_asset, pid, hash, size}, _from, state) do
    if Map.has_key?(state.sessions, pid) and valid_hash?(hash) and is_integer(size) do
      {:reply, Home.Render.AssetTransfer.listen(hash, size, cache_path(state, hash)), state}
    else
      {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call(:input_cap, _from, state), do: {:reply, state.input_cap, state}

  # The lease must be on our input capability and live (renewing it checks both).
  def handle_call({:route_input, lease, target}, _from, state) do
    if state.input_cap != nil and lease.cap == state.input_cap and
         safe(fn -> Home.Lease.renew(lease) end) == :ok do
      state = clear_route(state)
      monitor = Process.monitor(lease.holder)
      {:reply, :ok, %{state | input_route: %{ref: lease.ref, target: target, monitor: monitor}}}
    else
      {:reply, {:error, :invalid_lease}, state}
    end
  end

  def handle_call({:unroute_input, ref}, _from, %{input_route: %{ref: ref}} = state),
    do: {:reply, :ok, clear_route(state)}

  def handle_call({:unroute_input, _ref}, _from, state), do: {:reply, :ok, state}

  def handle_call(:shown, _from, state), do: {:reply, top(state), state}
  def handle_call(:frame, _from, state), do: {:reply, state.frame, state}

  def handle_call({:inject, _event}, _from, %{renderer: nil} = state),
    do: {:reply, {:error, :not_rendering}, state}

  def handle_call({:inject, event}, _from, state),
    do: {:reply, EmergeSkia.inject_input(state.renderer, event), state}

  def handle_call({:capture, _opts}, _from, %{renderer: nil} = state),
    do: {:reply, {:error, :not_rendering}, state}

  def handle_call({:capture, opts}, _from, state),
    do: {:reply, EmergeSkia.render_to_pixels(state.renderer, opts), state}

  @impl true
  def handle_info({:asset, pid, logical, hash, data}, state) do
    with %{} = entry <- state.sessions[pid],
         true <- safe_logical?(logical),
         ^hash <- hash(data) do
      path = cache_path(state, hash)
      tmp = path <> ".tmp#{System.unique_integer([:positive])}"
      File.write!(tmp, data)
      File.rename!(tmp, path)
      link_file(state, entry, logical, hash)
    else
      _ -> Logger.warning("render: dropped asset #{inspect(logical)} from #{inspect(pid)}")
    end

    {:noreply, state}
  end

  def handle_info({:link, pid, logical, hash}, state) do
    with %{} = entry <- state.sessions[pid],
         true <- safe_logical?(logical) and valid_hash?(hash),
         true <- File.regular?(cache_path(state, hash)) do
      link_file(state, entry, logical, hash)
    else
      _ -> Logger.warning("render: cannot link asset #{inspect(logical)} for #{inspect(pid)}")
    end

    {:noreply, state}
  end

  def handle_info({:upload, pid, bin}, state) do
    if top(state) == pid and state.renderer != nil do
      case EmergeSkia.upload_tree_binary(state.renderer, bin) do
        :ok -> {:noreply, %{state | synced?: true}}
        error -> {:noreply, log_error(state, :upload, error)}
      end
    else
      {:noreply, state}
    end
  end

  # Patches are relative to the session's last full tree; until this renderer has one
  # (after a resync request), they are dropped.
  def handle_info({:patch, pid, bin}, state) do
    if top(state) == pid and state.renderer != nil and state.synced? do
      case EmergeSkia.patch_tree_binary(state.renderer, bin) do
        :ok -> {:noreply, state}
        error -> {:noreply, log_error(state, :patch, error)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:configure, pid, view}, state) do
    case state.sessions do
      %{^pid => entry} ->
        updated = %{entry | view: view}

        if top(state) == pid and state.renderer != nil do
          previous = renderer_config(state, entry)
          _ = EmergeSkia.configure(state.renderer, previous, renderer_config(state, updated))
        end

        {:noreply, put_in(state.sessions[pid], updated)}

      _ ->
        {:noreply, state}
    end
  end

  # Frames of a hidden session, or before the tree with the element is up, are dropped.
  def handle_info({:video_frame, pid, target, frame}, state) do
    if top(state) == pid and state.renderer != nil and state.synced? do
      case EmergeSkia.submit_video_frame(state.renderer, target, frame) do
        :ok -> {:noreply, state}
        error -> {:noreply, log_error(state, :video_frame, error)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:emerge_skia_event, event}, state) do
    if pid = input_target(state, event) do
      send(pid, {:home_render_input, self(), event})
      Activity.emit(state.cap, :input, input_kind(event), %{session: pid})
    end

    {:noreply, state}
  end

  def handle_info({:emerge_skia_close, reason}, state) do
    if pid = top(state), do: send(pid, {:home_render_close, self(), reason})
    {:noreply, state}
  end

  def handle_info({:emerge_skia_frame, frame}, state) do
    Activity.emit(state.cap, :display, :frame, %{session: top(state), fps: nil})
    {:noreply, %{state | frame: frame}}
  end

  def handle_info({:emerge_skia_log, level, source, message}, state) do
    if level in [:warning, :error], do: Logger.log(level, "render: emerge #{source}: #{message}")
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{input_route: %{monitor: ref}} = state),
    do: {:noreply, %{state | input_route: nil}}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, drop(state, pid)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_renderer(state)
    :ok
  end

  ## Internals

  defp top(%{stack: [pid | _]}), do: pid
  defp top(_), do: nil

  # Without an :input capability, the session on top gets the input. With one, only
  # the process its lease holder routed it to; element events (ids of the drawn tree)
  # only if that is the drawn session.
  defp input_target(%{input_cap: nil} = state, _event), do: top(state)
  defp input_target(%{input_route: nil}, _event), do: nil

  defp input_target(%{input_route: %{target: target}} = state, event) do
    if raw_input?(event) or target == top(state), do: target
  end

  defp raw_input?({kind, _}) when is_atom(kind), do: true
  defp raw_input?(_), do: false

  defp clear_route(%{input_route: nil} = state), do: state

  defp clear_route(%{input_route: route} = state) do
    Process.demonitor(route.monitor, [:flush])
    %{state | input_route: nil}
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # A session is known from its first asset offer; it is drawn once attached.
  defp entry(state, pid) do
    case state.sessions do
      %{^pid => entry} ->
        {entry, state}

      _ ->
        dir =
          Path.join([
            state.dir,
            "sessions",
            Integer.to_string(System.unique_integer([:positive]))
          ])

        File.mkdir_p!(dir)
        entry = %{monitor: Process.monitor(pid), view: %{}, dir: dir}
        {entry, put_in(state.sessions[pid], entry)}
    end
  end

  defp drop(state, pid) do
    case Map.pop(state.sessions, pid) do
      {nil, _} ->
        state

      {entry, sessions} ->
        Process.demonitor(entry.monitor, [:flush])
        File.rm_rf(entry.dir)
        was_top? = top(state) == pid
        if pid in state.stack, do: emit(state, :session_stopped, pid)
        state = %{state | sessions: sessions, stack: List.delete(state.stack, pid)}
        if was_top?, do: show_top(state, true), else: state
    end
  end

  # (Re)start the renderer for the top session. `resync?` asks that session for a full
  # tree; a freshly attached session sends one on its own after `attach/3` returns.
  defp show_top(state, resync?) do
    state = stop_renderer(state)

    case state.stack do
      [] ->
        emit(state, :blank, nil)
        %{state | frame: nil}

      [pid | _] ->
        case EmergeSkia.start(renderer_config(state, state.sessions[pid])) do
          {:ok, renderer} ->
            :ok = EmergeSkia.set_input_target(renderer, self())
            :ok = EmergeSkia.set_log_target(renderer, self())
            if resync?, do: send(pid, {:home_render_resync, self()})
            %{state | renderer: renderer, synced?: false}

          {:error, reason} ->
            Logger.error("render: renderer start failed: #{inspect(reason)}")
            state
        end
    end
  rescue
    error ->
      Logger.error("render: renderer start failed: #{Exception.message(error)}")
      %{state | renderer: nil, synced?: false}
  end

  defp stop_renderer(%{renderer: nil} = state), do: state

  defp stop_renderer(state) do
    _ = EmergeSkia.stop(state.renderer)
    %{state | renderer: nil, synced?: false}
  catch
    _, _ -> %{state | renderer: nil, synced?: false}
  end

  # The display's own output and renderer settings; the session's fonts, input
  # subscriptions and assets.
  defp renderer_config(state, entry) do
    %Emerge.Config{} = config = state.config
    view = entry.view

    output =
      case config.output do
        %Emerge.Config.Headless{} = headless -> %{headless | target: self()}
        other -> other
      end

    %Emerge.Config{
      config
      | output: output,
        input: Map.get(view, :input, config.input),
        assets: %Emerge.Config.Assets{
          otp_app: :home_base,
          sources: [entry.dir],
          fonts: Map.get(view, :fonts, [])
        }
    }
  end

  defp link_file(state, entry, logical, hash) do
    dest = Path.join(entry.dir, logical)
    File.mkdir_p!(Path.dirname(dest))
    File.rm(dest)

    with {:error, _} <- File.ln(cache_path(state, hash), dest),
         do: File.cp!(cache_path(state, hash), dest)
  end

  defp cache_path(state, hash), do: Path.join([state.dir, "assets", hash])

  defp safe_logical?(logical) when is_binary(logical) do
    logical != "" and Path.type(logical) == :relative and ".." not in Path.split(logical)
  end

  defp safe_logical?(_), do: false

  defp valid_hash?(hash), do: is_binary(hash) and hash =~ ~r/\A[0-9a-f]{64}\z/

  @doc false
  def hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp emit(state, event, pid), do: Activity.emit(state.cap, :display, event, %{session: pid})

  defp input_kind({_id, event, _}) when event in [:key_down, :key_up, :key_press], do: :key
  defp input_kind({_id, :scroll, _}), do: :scroll
  defp input_kind({:key, _}), do: :key
  defp input_kind({:cursor_scroll, _}), do: :scroll
  defp input_kind(_), do: :pointer

  defp log_error(state, what, error) do
    Logger.warning("render: #{what} failed: #{inspect(error)}")
    state
  end
end
