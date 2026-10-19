defmodule Home.Registry do
  @moduledoc """
  Cluster-wide view of capabilities, backed by `:pg`, plus this node's own identity and
  area. Capability up/down changes (including whole nodes leaving) are broadcast locally
  on PubSub topic `"registry"` as `{:capability_up, info}` / `{:capability_down, pid}`.

  Area comes from Home Assistant (`refresh_area/0`) and is persisted, so it survives HA
  being down. Until the first lookup it is `nil`, and area-scoped queries skip this node.
  The lookup runs at boot, every `ha: [area_refresh: ms]` (default 3 h), and whenever
  `:ha_url` or `:ha_token` change in `Home.Secrets`. It runs in a task under
  `Home.TaskSupervisor`, so a slow or hung HA never blocks the registry; the registry
  only applies the result. Area changes are broadcast on `"registry"` (cluster-wide) as
  `{:area_changed, node, area}`.
  """

  use GenServer
  require Logger

  @scope :home
  @table __MODULE__
  @cache_ttl 1_000
  @ha_timeout 10_000

  def start_link(manifest), do: GenServer.start_link(__MODULE__, manifest, name: __MODULE__)

  @doc """
  List capabilities across the cluster. Filters: `kind:`, `area:`, `node:`.
  Returns info maps (see `Home.Capability.Server`), sorted by ref.
  """
  def list(filters \\ []) do
    kinds = if k = filters[:kind], do: List.wrap(k), else: Home.Capability.kinds()

    kinds
    |> Enum.flat_map(&:pg.get_members(@scope, {:capability, &1}))
    |> Enum.filter(&(is_nil(filters[:node]) or node(&1) == filters[:node]))
    |> Task.async_stream(&cached_info/1, timeout: 6_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, {:ok, info}} -> [info]
      _ -> []
    end)
    |> Enum.filter(&(is_nil(filters[:area]) or &1.area == filters[:area]))
    |> Enum.sort_by(& &1.ref)
  end

  @doc "The pid of the server for `{node, cap_id}`."
  def whereis({node, id}) do
    case :pg.get_members(@scope, {:cap, node, id}) do
      [pid | _] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  def device_id, do: lookup(:device_id)
  def area, do: lookup(:area)

  @doc "Set this node's area (persisted). Normally called by `refresh_area/0`."
  def put_area(area), do: GenServer.call(__MODULE__, {:put_area, area})

  @doc """
  Ask Home Assistant for this node's area now. Returns `{:ok, area}` (`nil` if the device
  has no area in HA) or `{:error, reason}`; on error the last known area is kept.

  Callers that ask while a lookup is running share its result. A lookup that takes
  longer than `ha: [lookup_timeout: ms]` (default three times `ha: [timeout: ms]`) is
  killed and answers `{:error, :timeout}`. The default call `timeout` is the lookup
  timeout plus 5 s.
  """
  def refresh_area(timeout \\ nil) do
    GenServer.call(__MODULE__, :refresh_area, timeout || lookup_timeout() + 5_000)
  end

  defp lookup_timeout do
    ha = Home.config(:ha, [])
    Keyword.get(ha, :lookup_timeout, 3 * Keyword.get(ha, :timeout, @ha_timeout))
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp cached_info(pid) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, {:info, pid}) do
      [{_, info, at}] when now - at < @cache_ttl ->
        {:ok, info}

      _ ->
        info = Home.Capability.Server.info(pid)
        :ets.insert(@table, {{:info, pid}, info, now})
        {:ok, info}
    end
  catch
    :exit, _ -> :error
  end

  ## Server

  @impl true
  def init(manifest) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ets.insert(@table, {:device_id, manifest.device_id})
    :ets.insert(@table, {:area, read_area()})

    {_ref, _groups} = :pg.monitor_scope(@scope)
    Phoenix.PubSub.subscribe(Home.PubSub, "leases")
    Phoenix.PubSub.subscribe(Home.PubSub, "registry")
    Phoenix.PubSub.subscribe(Home.PubSub, "secrets:changed")

    ha = Home.config(:ha, [])
    send(self(), :refresh_area)

    {:ok,
     %{
       area_refresh: Keyword.get(ha, :area_refresh, :timer.hours(3)),
       ha_timeout: Keyword.get(ha, :timeout, @ha_timeout),
       lookup_timeout: lookup_timeout(),
       # The running HA lookup: %{task: Task.t(), timer: reference(), waiters: [from]}.
       lookup: nil
     }}
  end

  @impl true
  def handle_call({:put_area, area}, _from, state) do
    store_area(area)
    {:reply, :ok, state}
  end

  def handle_call(:refresh_area, from, state) do
    {:noreply, start_lookup(state, [from])}
  end

  @impl true
  def handle_info(:refresh_area, state) do
    Process.send_after(self(), :refresh_area, state.area_refresh)
    {:noreply, start_lookup(state, [])}
  end

  def handle_info({ref, result}, %{lookup: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, lookup_done(state, apply_area(result))}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{lookup: %{task: %{ref: ref}}} = state) do
    {:noreply, lookup_done(state, log_failure({:error, {:lookup_failed, reason}}))}
  end

  def handle_info({:lookup_timeout, ref}, %{lookup: %{task: %{ref: ref} = task}} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, lookup_done(state, log_failure({:error, :timeout}))}
  end

  def handle_info({_ref, :join, {:capability, _kind}, pids}, state) do
    for pid <- pids do
      Task.start(fn ->
        with {:ok, info} <- cached_info(pid),
             do: Phoenix.PubSub.local_broadcast(Home.PubSub, "registry", {:capability_up, info})
      end)
    end

    {:noreply, state}
  end

  def handle_info({_ref, :leave, {:capability, _kind}, pids}, state) do
    for pid <- pids do
      :ets.delete(@table, {:info, pid})
      Phoenix.PubSub.local_broadcast(Home.PubSub, "registry", {:capability_down, pid})
    end

    {:noreply, state}
  end

  # Lease and hardware changes alter a capability's status: drop the cached info.
  def handle_info({:lease, _event, %{cap: cap}}, state), do: invalidate(cap, state)
  def handle_info({:hardware, cap, _}, state), do: invalidate(cap, state)

  # Another node moved: its capabilities report a new area.
  def handle_info({:area_changed, peer, _area}, state) when peer != node() do
    :ets.select_delete(@table, [{{{:info, :"$1"}, :_, :_}, [{:==, {:node, :"$1"}, peer}], [true]}])

    {:noreply, state}
  end

  # New credentials: a lookup still running with the old ones starts over with the new
  # ones, and its callers get the new result.
  def handle_info({:secrets_changed, keys}, state) do
    if :ha_url in keys or :ha_token in keys do
      waiters = if state.lookup, do: cancel_lookup(state.lookup), else: []
      {:noreply, start_lookup(%{state | lookup: nil}, waiters)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp invalidate(cap, state) do
    with {:ok, pid} <- whereis(cap), do: :ets.delete(@table, {:info, pid})
    {:noreply, state}
  end

  # Start an HA lookup in a task, or join the one that is running.
  defp start_lookup(%{lookup: %{} = running} = state, waiters),
    do: %{state | lookup: %{running | waiters: waiters ++ running.waiters}}

  defp start_lookup(state, waiters) do
    device_id = device_id()
    timeout = state.ha_timeout

    task =
      Task.Supervisor.async_nolink(Home.TaskSupervisor, fn ->
        with {:ok, url} <- Home.Secrets.fetch(:ha_url),
             {:ok, token} <- Home.Secrets.fetch(:ha_token) do
          Home.HA.Client.area_for_device(url, token, device_id, timeout: timeout)
        else
          :error -> {:error, :no_ha_credentials}
        end
      end)

    timer = Process.send_after(self(), {:lookup_timeout, task.ref}, state.lookup_timeout)
    %{state | lookup: %{task: task, timer: timer, waiters: waiters}}
  end

  defp cancel_lookup(%{task: task, timer: timer, waiters: waiters}) do
    Process.cancel_timer(timer)
    Task.shutdown(task, :brutal_kill)
    waiters
  end

  defp lookup_done(%{lookup: %{timer: timer, waiters: waiters}} = state, result) do
    Process.cancel_timer(timer)
    for from <- waiters, do: GenServer.reply(from, result)
    %{state | lookup: nil}
  end

  defp apply_area({:ok, area} = result) do
    if area != area(), do: store_area(area)
    result
  end

  defp apply_area({:error, :no_ha_credentials} = error), do: error
  defp apply_area(error), do: log_failure(error)

  defp log_failure({:error, reason} = error) do
    Logger.warning("HA area lookup failed: #{inspect(reason)}")
    error
  end

  defp store_area(area) do
    :ets.insert(@table, {:area, area})
    tmp = area_file() <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(area))
    File.rename!(tmp, area_file())
    :ets.match_delete(@table, {{:info, :_}, :_, :_})
    Phoenix.PubSub.broadcast(Home.PubSub, "registry", {:area_changed, node(), area})
  end

  defp read_area do
    with {:ok, bin} <- File.read(area_file()),
         area when is_binary(area) <- :erlang.binary_to_term(bin) do
      area
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp area_file, do: Path.join(Home.data_dir(), "area")
end
