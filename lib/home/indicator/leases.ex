defmodule Home.Indicator.Leases do
  @moduledoc """
  Solve controller behind `Home.Indicator`: which capabilities are on and who holds them.

  Starts from `Home.Registry.list/0` and then follows PubSub `"leases"` (lease events
  and hardware on/off, cluster-wide) and `"registry"` (capabilities coming and going,
  area changes).

  Exposes `%{node: node(), in_use: [row], idle: count}`. A row is a capability that is
  leased, or `:on_request` hardware that is on:

      %{ref: {node, id}, id: id, kind: kind, device: device_id, area: area | nil,
        hardware: :on | :off, holders: [%{node: node, name: name, purpose: purpose}]}

  `name` is the holder node's device id when one of its capabilities is known, else the
  node's short name. Params: `node:` only that node's capabilities (default all),
  `hide:` a pid whose leases are left out (the indicator's own render session).

  Event `:revoke_all` calls `Home.Lease.revoke_all/0` on this node.
  """

  use Solve.Controller, events: [:revoke_all]

  @impl Solve.Controller
  def init(params, _dependencies) when is_map(params) do
    # Subscribe before listing so nothing between the two is missed; every update
    # below is idempotent, so seeing a change in both is harmless.
    Phoenix.PubSub.subscribe(Home.PubSub, "leases")
    Phoenix.PubSub.subscribe(Home.PubSub, "registry")
    state = %{caps: %{}, pids: %{}, node: params_node(params), hide: params[:hide]}
    Enum.reduce(Home.Registry.list(), state, &put_cap(&2, &1))
  end

  def revoke_all(_payload, state) do
    Home.Lease.revoke_all()
    state
  end

  def handle_info({:lease, :acquired, %{holder: hide}}, %{hide: hide} = state), do: state

  def handle_info({:lease, :acquired, %{ref: ref, cap: cap} = lease}, state) do
    update_cap(state, cap, fn row ->
      put_in(row.held_by[ref], %{holder: lease.holder, purpose: lease.purpose})
    end)
  end

  def handle_info({:lease, event, %{ref: ref, cap: cap}}, state)
      when event in [:released, :expired, :revoked] do
    update_cap(state, cap, fn row -> %{row | held_by: Map.delete(row.held_by, ref)} end)
  end

  def handle_info({:hardware, cap, hardware}, state),
    do: update_cap(state, cap, &%{&1 | hardware: hardware})

  def handle_info({:capability_up, info}, state), do: put_cap(state, info)

  def handle_info({:capability_down, pid}, state) do
    case Map.pop(state.pids, pid) do
      {nil, _} -> state
      {ref, pids} -> %{state | pids: pids, caps: Map.delete(state.caps, ref)}
    end
  end

  def handle_info({:area_changed, node, area}, state) do
    caps =
      Map.new(state.caps, fn
        {{^node, _} = ref, row} -> {ref, %{row | area: area}}
        other -> other
      end)

    %{state | caps: caps}
  end

  def handle_info(_message, state), do: state

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    names = for {{node, _}, row} <- state.caps, into: %{}, do: {node, row.device}

    rows =
      for {ref, row} <- Enum.sort(state.caps), is_nil(state.node) or elem(ref, 0) == state.node do
        row
      end

    {in_use, idle} = Enum.split_with(rows, &in_use?/1)

    %{
      node: node(),
      in_use: Enum.map(in_use, &expose_row(&1, names)),
      idle: length(idle)
    }
  end

  defp in_use?(row),
    do: row.held_by != %{} or (row.availability == :on_request and row.hardware == :on)

  defp expose_row(row, names) do
    holders =
      for {_ref, %{holder: holder, purpose: purpose}} <- Enum.sort(row.held_by) do
        node = node(holder)
        %{node: node, name: Map.get_lazy(names, node, fn -> short(node) end), purpose: purpose}
      end

    row
    |> Map.take([:ref, :id, :kind, :device, :area, :hardware])
    |> Map.put(:holders, holders)
  end

  defp short(node), do: node |> Atom.to_string() |> String.split("@") |> hd()

  defp put_cap(state, info) do
    {node, id} = info.ref

    row = %{
      ref: info.ref,
      id: id,
      kind: info.cap.kind,
      availability: info.cap.availability,
      device: info.device_id || short(node),
      area: info.area,
      hardware: info.hardware,
      pid: info.pid,
      held_by:
        for(
          lease <- info.held_by,
          lease.holder != state.hide,
          into: %{},
          do: {lease.ref, Map.take(lease, [:holder, :purpose])}
        )
    }

    # A restarted capability server comes back under a new pid.
    pids =
      state.pids
      |> Map.reject(fn {_pid, ref} -> ref == info.ref end)
      |> Map.put(info.pid, info.ref)

    %{state | caps: Map.put(state.caps, info.ref, row), pids: pids}
  end

  defp update_cap(state, ref, fun) do
    case state.caps do
      %{^ref => row} -> put_in(state.caps[ref], fun.(row))
      _ -> state
    end
  end

  defp params_node(params), do: Map.get(params, :node)
end
