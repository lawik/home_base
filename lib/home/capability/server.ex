defmodule Home.Capability.Server do
  @moduledoc """
  One process per capability. Owns the adapter, the hardware on/off state and every lease
  on the capability. Joins `:pg` groups `{:capability, kind}` and `{:cap, node, id}`.
  """

  use GenServer, restart: :transient
  require Logger

  alias Home.{Activity, Capability, Lease}

  @scope :home

  def start_link(%Capability{} = cap) do
    GenServer.start_link(__MODULE__, cap)
  end

  def child_spec(%Capability{id: id} = cap) do
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [cap]}, restart: :transient}
  end

  @doc """
  The capability as `Home.Registry.list/1` returns it: `%{ref, cap, pid, device_id, area,
  status (:idle | :leased), hardware (:on | :off), leases (count), held_by: [%{ref,
  holder, purpose}]}`.
  """
  def info(pid, timeout \\ 5_000), do: GenServer.call(pid, :info, timeout)

  def local_servers do
    Capability.kinds()
    |> Enum.flat_map(&:pg.get_local_members(@scope, {:capability, &1}))
  end

  @doc false
  def expire_overdue(pid, now \\ System.monotonic_time(:millisecond)),
    do: GenServer.call(pid, {:expire_overdue, now})

  ## Server

  @impl true
  def init(cap) do
    {adapter, opts} = adapter(cap)
    cap = %{cap | adapter: adapter, meta: Map.merge(cap.meta, Map.new(opts))}

    case adapter.init(cap) do
      {:ok, astate} ->
        state = %{cap: cap, adapter: adapter, astate: astate, hardware: :off, leases: %{}}
        state = if cap.availability == :always, do: hardware_on(state), else: state

        unless cap.availability == :off do
          :ok = :pg.join(@scope, {:capability, cap.kind}, self())
          :ok = :pg.join(@scope, {:cap, node(), cap.id}, self())
        end

        {:ok, state}

      {:error, reason} ->
        Logger.error("capability #{cap.id} failed to init: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, describe(state), state}

  def handle_call({:acquire, holder, purpose}, _from, state) do
    %{cap: cap, leases: leases} = state

    cond do
      cap.availability == :off ->
        {:reply, {:error, :off}, state}

      map_size(leases) > 0 and not Capability.shareable?(cap) ->
        {:reply, {:error, :busy}, state}

      true ->
        state = hardware_on(state)
        ref = make_ref()

        lease = %Lease{
          ref: ref,
          cap: cap_ref(state),
          holder: holder,
          server: self(),
          endpoint: state.adapter.endpoint(state.astate),
          purpose: purpose
        }

        entry = %{lease: lease, monitor: Process.monitor(holder), renewed_at: now()}
        state = put_in(state.leases[ref], entry)
        announce(state, :acquired, lease)
        {:reply, {:ok, lease}, state}
    end
  end

  def handle_call({:release, ref}, _from, state) do
    {:reply, :ok, drop(state, ref, :released)}
  end

  def handle_call({:renew, ref}, _from, state) do
    case state.leases do
      %{^ref => entry} ->
        state = put_in(state.leases[ref], %{entry | renewed_at: now()})
        announce(state, :renewed, entry.lease)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :unknown_lease}, state}
    end
  end

  def handle_call({:handover, ref, pid}, _from, state) do
    case state.leases do
      %{^ref => entry} ->
        Process.demonitor(entry.monitor, [:flush])
        entry = %{entry | lease: %{entry.lease | holder: pid}, monitor: Process.monitor(pid)}
        {:reply, :ok, put_in(state.leases[ref], entry)}

      _ ->
        {:reply, {:error, :unknown_lease}, state}
    end
  end

  def handle_call({:expire_overdue, now}, _from, state) do
    max_age = Capability.max_age(state.cap)

    overdue =
      for {ref, %{renewed_at: at}} <- state.leases, now - at >= max_age, do: ref

    state =
      Enum.reduce(overdue, state, fn ref, state ->
        send(state.leases[ref].lease.holder, {:lease_expired, ref})
        drop(state, ref, :expired)
      end)

    {:reply, length(overdue), state}
  end

  def handle_call(:revoke_all, _from, state) do
    state =
      Enum.reduce(Map.keys(state.leases), state, fn ref, state ->
        send(state.leases[ref].lease.holder, {:lease_revoked, ref})
        drop(state, ref, :revoked)
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    case Enum.find(state.leases, fn {_ref, entry} -> entry.monitor == mref end) do
      {ref, _} -> {:noreply, drop(state, ref, :released)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    # Adapters may run processes that report back to the capability (e.g. levels).
    if function_exported?(state.adapter, :handle_info, 2) do
      {:ok, astate} = state.adapter.handle_info(msg, state.astate)
      {:noreply, %{state | astate: astate}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.hardware == :on, do: state.adapter.stop(state.astate)
    :ok
  end

  ## Internals

  defp adapter(%Capability{adapter: {mod, opts}}), do: {mod, opts}
  defp adapter(%Capability{adapter: nil}), do: {Home.Adapters.Null, []}
  defp adapter(%Capability{adapter: mod}), do: {mod, []}

  defp drop(state, ref, event) do
    case Map.pop(state.leases, ref) do
      {nil, _} ->
        state

      {entry, leases} ->
        Process.demonitor(entry.monitor, [:flush])
        state = %{state | leases: leases}
        announce(state, event, entry.lease)

        if leases == %{} and state.cap.availability == :on_request,
          do: hardware_off(state),
          else: state
    end
  end

  defp hardware_on(%{hardware: :on} = state), do: state

  defp hardware_on(state) do
    {:ok, astate} = state.adapter.start(state.astate)
    state = %{state | astate: astate, hardware: :on}
    broadcast_hardware(state)
    state
  end

  defp hardware_off(%{hardware: :off} = state), do: state

  defp hardware_off(state) do
    {:ok, astate} = state.adapter.stop(state.astate)
    state = %{state | astate: astate, hardware: :off}
    broadcast_hardware(state)
    state
  end

  defp broadcast_hardware(state) do
    Phoenix.PubSub.broadcast(Home.PubSub, "leases", {:hardware, cap_ref(state), state.hardware})
  end

  defp announce(_state, event, %Lease{} = lease) do
    info = %{ref: lease.ref, cap: lease.cap, holder: lease.holder, purpose: lease.purpose}
    Phoenix.PubSub.broadcast(Home.PubSub, "leases", {:lease, event, info})

    Activity.emit(lease.cap, :lease, event, %{
      holder: lease.holder,
      holder_node: node(lease.holder)
    })
  end

  defp describe(state) do
    %{
      ref: cap_ref(state),
      cap: state.cap,
      pid: self(),
      device_id: Home.Registry.device_id(),
      area: Home.Registry.area(),
      status: if(state.leases == %{}, do: :idle, else: :leased),
      hardware: state.hardware,
      leases: map_size(state.leases),
      held_by:
        for {ref, %{lease: lease}} <- state.leases do
          %{ref: ref, holder: lease.holder, purpose: lease.purpose}
        end
    }
  end

  defp cap_ref(state), do: {node(), state.cap.id}
  defp now, do: System.monotonic_time(:millisecond)
end
