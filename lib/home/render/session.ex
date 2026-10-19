defmodule Home.Render.Session do
  @moduledoc """
  One app rendered on a (possibly remote) display. Runs on the app's node, starts and
  owns the app's viewport, holds the display lease and talks to the display's
  `Home.Render.Compositor`.

  The viewport's `Home.Render.Remote` adapter hands it each encoded tree and patch;
  the session keeps the latest assigned tree, so a compositor that restarts its
  renderer, or a new display after `move/2`, gets a full tree without the app noticing.
  Before a tree goes out, every asset it references (images, and the app's fonts) is
  offered by hash; the display caches what it lacks.

  Losing the lease (revoked or expired) stops the session and its app.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Home.Lease
  alias Home.Render.{Assets, AssetTransfer, Compositor, InputLease, Retained}

  defstruct [
    :app,
    :viewport,
    :lease,
    :compositor,
    :tree,
    :input_target,
    :otp_app,
    :renew,
    :input,
    layer: :normal,
    view: %{},
    hashes: %{},
    files: %{},
    retained: %Home.Render.Retained{},
    sent: MapSet.new()
  ]

  def start_link({app, target, opts}), do: GenServer.start_link(__MODULE__, {app, target, opts})

  @doc false
  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}

  def move(session, target), do: GenServer.call(session, {:move, target}, 30_000)
  def target(session), do: GenServer.call(session, :target)
  def viewport(session), do: GenServer.call(session, :viewport)

  ## Called from Home.Render.Remote, in the viewport and its lifecycle process.

  @doc false
  def renderer_started(session, config),
    do: GenServer.call(session, {:renderer_started, config}, 30_000)

  @doc false
  def renderer_stopped(session) do
    send(session, :renderer_stopped)
    :ok
  end

  @doc false
  def configure(session, config), do: GenServer.call(session, {:configure, config})
  @doc false
  def set_input_target(session, pid), do: GenServer.call(session, {:input_target, pid})
  @doc false
  def upload(session, bin, tree, files \\ %{}),
    do: GenServer.call(session, {:upload, bin, tree, files}, 60_000)

  @doc false
  def patch(session, bin, tree, files \\ %{}),
    do: GenServer.call(session, {:patch, bin, tree, files}, 60_000)

  ## Server

  @impl true
  def init({{module, app_opts}, target, opts}) do
    Process.flag(:trap_exit, true)

    with {:ok, lease} <- acquire(target, opts) do
      runtime = [adapter: Home.Render.Remote, adapter_opts: [session: self()]]

      case module.start_link(Keyword.put(app_opts, :runtime, runtime)) do
        {:ok, viewport} ->
          state = %__MODULE__{app: module, viewport: viewport, layer: opts[:layer] || :normal}
          {:ok, state |> adopt(lease) |> take_input() |> schedule_renew()}

        {:error, reason} ->
          Lease.release(lease)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:renderer_started, config}, _from, state) do
    state = %{state | otp_app: config.assets.otp_app, view: view(state, config)}

    case attach(state, state.compositor) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:configure, config}, _from, state) do
    view = view(state, config)

    if view != state.view do
      state = sync_assets(%{state | view: view}, state.compositor, font_paths(view))
      Compositor.configure(state.compositor, self(), view)
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:input_target, pid}, _from, state),
    do: {:reply, :ok, %{state | input_target: pid}}

  def handle_call({:upload, bin, tree, files}, _from, state) do
    state = add_files(%{state | tree: tree}, files)
    state = sync_assets(state, state.compositor, image_paths(tree))
    Compositor.upload(state.compositor, self(), bin)
    {:reply, :ok, state}
  end

  def handle_call({:patch, bin, tree, files}, _from, state) do
    state = add_files(%{state | tree: tree}, files)
    state = sync_assets(state, state.compositor, image_paths(tree))
    Compositor.patch(state.compositor, self(), bin)
    {:reply, :ok, state}
  end

  def handle_call({:move, target}, _from, %{lease: %{cap: target}} = state),
    do: {:reply, :ok, state}

  # The app keeps running; only the compositor changes. The new display gets the
  # assets and the latest full tree, then the old one lets go.
  def handle_call({:move, target}, _from, state) do
    old = state.lease

    with {:ok, lease} <- acquire(target, purpose: old.purpose) do
      case attach(adopt(%{state | sent: MapSet.new()}, lease), lease.endpoint) do
        {:ok, new} ->
          resync(new)
          InputLease.stop(state.input)
          safe(fn -> Compositor.detach(old.endpoint, self()) end)
          Lease.release(old)
          {:reply, :ok, new |> take_input() |> schedule_renew()}

        {:error, _} = error ->
          Lease.release(lease)
          {:reply, error, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:target, _from, state), do: {:reply, state.lease.cap, state}
  def handle_call(:viewport, _from, state), do: {:reply, state.viewport, state}

  @impl true
  def handle_info({:home_render_input, comp, event}, %{compositor: comp} = state) do
    if state.input_target, do: send(state.input_target, {:emerge_skia_event, event})
    {:noreply, %{state | retained: Retained.record(state.retained, event)}}
  end

  def handle_info({:home_render_close, comp, reason}, %{compositor: comp} = state) do
    if state.input_target, do: send(state.input_target, {:emerge_skia_close, reason})
    {:noreply, state}
  end

  def handle_info({:home_render_resync, comp}, %{compositor: comp} = state) do
    resync(state)
    {:noreply, state}
  end

  def handle_info(:renew, state) do
    _ = safe(fn -> Lease.renew(state.lease) end)
    {:noreply, schedule_renew(state)}
  end

  def handle_info({event, ref}, %{lease: %{ref: ref}} = state)
      when event in [:lease_expired, :lease_revoked] do
    {:stop, {:shutdown, event}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{viewport: pid} = state) do
    {:stop, reason, %{state | viewport: nil}}
  end

  def handle_info(:renderer_stopped, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # The viewport traps exits and ignores a :normal one from us.
    if state.viewport, do: Process.exit(state.viewport, :shutdown)
    InputLease.stop(state.input)

    if state.lease do
      safe(fn -> Compositor.detach(state.lease.endpoint, self()) end)
      Lease.release(state.lease)
    end

    :ok
  end

  ## Internals

  defp acquire(target, opts) do
    purpose = Keyword.get(opts, :purpose, "render")

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

  defp adopt(state, lease), do: %{state | lease: lease, compositor: lease.endpoint}

  # The display's :input capability, if it has one (`Home.Render.InputLease`).
  defp take_input(state) do
    case InputLease.start_link(state.compositor, self(), state.lease.purpose) do
      {:ok, pid} -> %{state | input: pid}
      _ -> %{state | input: nil}
    end
  end

  # Fonts must be on the display before its renderer starts; images before the tree.
  defp attach(state, comp) do
    state = sync_assets(state, comp, font_paths(state.view) ++ image_paths(state.tree))

    case safe(fn -> Compositor.attach(comp, self(), state.view) end) do
      :ok -> {:ok, state}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp resync(%{tree: nil}), do: :ok

  # A new renderer: the full tree, with the scroll positions and focus the last one had.
  defp resync(state) do
    bin = Emerge.Engine.Serialization.encode_tree(Retained.restore(state.tree, state.retained))
    Compositor.upload(state.compositor, self(), bin)
  end

  defp sync_assets(state, comp, logicals) do
    new = Enum.reject(Enum.uniq(logicals), &MapSet.member?(state.sent, &1))

    if new == [] do
      state
    else
      {entries, state} = hashed(state, new)

      case safe(fn -> Compositor.missing(comp, self(), entries) end) do
        missing when is_list(missing) ->
          {sent, _} =
            Enum.reduce(entries, {state.sent, MapSet.new()}, fn {logical, hash}, {sent, done} ->
              cond do
                hash not in missing ->
                  {MapSet.put(sent, logical), done}

                hash in done ->
                  # Same bytes under another path: in the cache now, link it there.
                  Compositor.link(comp, self(), logical, hash)
                  {MapSet.put(sent, logical), done}

                send_asset(state, comp, logical, hash) == :ok ->
                  {MapSet.put(sent, logical), MapSet.put(done, hash)}

                true ->
                  {sent, done}
              end
            end)

          %{state | sent: sent}

        error ->
          Logger.warning("render: asset sync failed: #{inspect(error)}")
          state
      end
    end
  end

  # Small assets go in one message; large ones over TCP, then linked by a message (which
  # stays ordered before the tree that uses them).
  defp send_asset(state, comp, logical, hash) do
    path = source(state, logical)

    with {:ok, %File.Stat{size: size}} <- File.stat(path) do
      if size < AssetTransfer.threshold() do
        Compositor.put_asset(comp, self(), logical, hash, File.read!(path))
        :ok
      else
        with {:ok, receiver} <- safe(fn -> Compositor.receive_asset(comp, self(), hash, size) end),
             :ok <- AssetTransfer.send_file(receiver, path) do
          Compositor.link(comp, self(), logical, hash)
          :ok
        end
      end
    end
    |> case do
      :ok ->
        :ok

      error ->
        Logger.warning("render: sending asset #{logical} failed: #{inspect(error)}")
        error
    end
  end

  defp add_files(state, files) when map_size(files) == 0, do: state

  defp add_files(state, files) do
    hashes = Map.new(files, fn {logical, {_file, hash}} -> {logical, hash} end)
    %{state | files: Map.merge(state.files, files), hashes: Map.merge(state.hashes, hashes)}
  end

  defp hashed(state, logicals) do
    Enum.flat_map_reduce(logicals, state, fn logical, state ->
      case Map.fetch(state.hashes, logical) do
        {:ok, hash} ->
          {[{logical, hash}], state}

        :error ->
          case File.read(source(state, logical)) do
            {:ok, data} ->
              hash = Compositor.hash(data)
              {[{logical, hash}], put_in(state.hashes[logical], hash)}

            {:error, reason} ->
              Logger.warning("render: asset #{logical}: #{inspect(reason)}")
              {[], state}
          end
      end
    end)
  end

  # Rewritten runtime paths and ids (`Home.Render.Assets`), else the app's priv/.
  defp source(state, logical) do
    case state.files do
      %{^logical => {file, _hash}} -> file
      _ -> Path.join(to_string(:code.priv_dir(state.otp_app)), logical)
    end
  end

  # What the display's renderer needs from the app's config.
  defp view(state, %Emerge.Config{} = config) do
    fonts =
      for %Emerge.Config.Font{} = font <- config.assets.fonts do
        %Emerge.Config.Font{font | source: Assets.logical(font.source)}
      end

    %{fonts: fonts, input: config.input, layer: state.layer}
  end

  defp font_paths(view), do: Enum.map(Map.get(view, :fonts, []), & &1.source)

  @doc false
  def image_paths(tree), do: Assets.logical_paths(tree)

  defp schedule_renew(state) do
    if state.renew, do: Process.cancel_timer(state.renew)
    every = max(div(max_age(state.lease), 3), 100)
    %{state | renew: Process.send_after(self(), :renew, every)}
  end

  defp max_age(lease) do
    case safe(fn -> Home.Capability.Server.info(lease.server) end) do
      %{cap: cap} -> Home.Capability.max_age(cap)
      _ -> :timer.minutes(1)
    end
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
