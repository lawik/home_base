defmodule Home.Registry do
  @moduledoc """
  Cluster-wide view of capabilities, backed by `:pg`, plus this node's own identity and
  area. Capability up/down changes (including whole nodes leaving) are broadcast locally
  on PubSub topic `"registry"` as `{:capability_up, info}` / `{:capability_down, pid}`.

  Area comes from Home Assistant (`refresh_area/0`) and is persisted, so it survives HA
  being down. Until the first lookup it is `nil`, and area-scoped queries skip this node.
  """

  use GenServer
  require Logger

  @scope :home
  @table __MODULE__
  @cache_ttl 1_000

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

  @doc "Ask Home Assistant for this node's area now."
  def refresh_area(timeout \\ 15_000), do: GenServer.call(__MODULE__, :refresh_area, timeout)

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

    interval = Keyword.get(Home.config(:ha, []), :area_refresh, :timer.hours(3))
    if Home.config(:ha), do: send(self(), :refresh_area)

    {:ok, %{area_refresh: interval}}
  end

  @impl true
  def handle_call({:put_area, area}, _from, state) do
    store_area(area)
    {:reply, :ok, state}
  end

  def handle_call(:refresh_area, _from, state) do
    {:reply, do_refresh(), state}
  end

  @impl true
  def handle_info(:refresh_area, state) do
    _ = do_refresh()
    Process.send_after(self(), :refresh_area, state.area_refresh)
    {:noreply, state}
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
  def handle_info(_msg, state), do: {:noreply, state}

  defp invalidate(cap, state) do
    with {:ok, pid} <- whereis(cap), do: :ets.delete(@table, {:info, pid})
    {:noreply, state}
  end

  defp do_refresh do
    with {:ok, url} <- Home.Secrets.fetch(:ha_url),
         {:ok, token} <- Home.Secrets.fetch(:ha_token),
         {:ok, area} <- Home.HA.Client.area_for_device(url, token, device_id()) do
      if area != area(), do: store_area(area)
      {:ok, area}
    else
      :error ->
        {:error, :no_ha_credentials}

      {:error, reason} = error ->
        Logger.warning("HA area lookup failed: #{inspect(reason)}")
        error
    end
  end

  defp store_area(area) do
    :ets.insert(@table, {:area, area})
    File.write!(area_file(), :erlang.term_to_binary(area))
    :ets.match_delete(@table, {{:info, :_}, :_, :_})
    Phoenix.PubSub.broadcast(Home.PubSub, "registry", {:area_changed, node(), area})
  end

  defp read_area do
    case File.read(area_file()) do
      {:ok, bin} -> :erlang.binary_to_term(bin)
      _ -> nil
    end
  end

  defp area_file, do: Path.join(Home.data_dir(), "area")
end
