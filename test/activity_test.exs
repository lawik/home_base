defmodule Home.ActivityTest do
  use Home.Test.ClusterCase, async: false

  require Logger

  alias Home.Activity
  alias Home.Test.ActivityProbe

  # Every capability kind that emits activity, with the events the plan lists for it.
  @events [
    {"input0", :input, [:touch, :pointer, :key, :scroll]},
    {"disp0", :display, [:frame, :session_started, :session_stopped, :blank, :unblank]},
    {"mic0", :audio_in, [:stream_started, :stream_stopped, :level]},
    {"spk0", :audio_out, [:stream_started, :stream_stopped, :level]},
    {"cam0", :video_in, [:stream_started, :stream_stopped, :level]},
    {"pir0", :presence, [:detected, :cleared]},
    {"temp0", :sensor, [:reading]}
  ]

  @ring 16

  defp caps do
    for {id, kind, _} <- @events do
      availability = if kind == :video_in, do: :on_request, else: :always
      %{id: id, kind: kind, availability: availability, adapter: Home.Test.FakeAdapter}
    end
  end

  setup do
    opts = [capabilities: caps(), activity: [ring: @ring]]
    nodes = start_cluster("m6", a: opts, b: opts, c: opts)
    %{nodes: Enum.map(nodes, &elem(&1, 0))}
  end

  defp subscribe(node, what) do
    Node.spawn(node, ActivityProbe, :subscriber, [self(), what])
    assert_receive {:subscribed, ^node, pid}
    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp collect(node, timeout) do
    receive do
      {:activity, ^node, at, ev} -> [{at, ev} | collect(node, timeout)]
    after
      timeout -> []
    end
  end

  test "events of every kind reach every node's store; last/2 answers within 100 ms",
       %{nodes: [a, b, c] = nodes} do
    :ok = rpc(a, Home.Registry, :put_area, ["Kitchen"])

    latencies =
      for emitter <- [a, b], {id, kind, events} <- @events, event <- events do
        cap = {emitter, id}
        data = %{probe: System.unique_integer([:positive])}

        waiters =
          for n <- nodes do
            Task.async(fn -> rpc(n, ActivityProbe, :await_last, [cap, kind, data]) end)
          end

        assert rpc(emitter, Activity, :emit, [cap, kind, event, data]) == :ok

        for {:ok, us, ev} <- Task.await_many(waiters) do
          assert %Activity.Event{cap: ^cap, kind: ^kind, event: ^event} = ev
          assert ev.area == if(emitter == a, do: "Kitchen", else: nil)
          us
        end
        |> tap(&assert(length(&1) == 3, "#{inspect(cap)} #{event} missing on some node"))
      end
      |> List.flatten()

    sorted = Enum.sort(latencies)
    pct = fn p -> Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p))) / 1000 end

    Logger.warning(
      "activity emit -> last/2 on every node: n=#{length(sorted)} " <>
        "p50=#{pct.(0.5)}ms p95=#{pct.(0.95)}ms max=#{List.last(sorted) / 1000}ms"
    )

    assert List.last(sorted) < 100_000

    # last(kind: ...) is per cap, cluster-wide, newest first; area scopes by the event's area.
    for n <- nodes do
      assert [_, _] = evs = rpc(n, Activity, :last, [[kind: :input]])
      assert Enum.sort(Enum.map(evs, & &1.cap)) == [{a, "input0"}, {b, "input0"}]
      assert [first, second] = evs
      assert first.ts >= second.ts
      assert [%{cap: {^a, "input0"}}] = rpc(n, Activity, :last, [[kind: :input, area: "Kitchen"]])
      assert [] = rpc(n, Activity, :last, [[kind: :sensor, area: "Attic"]])
    end

    assert rpc(c, Activity, :last, [{c, "input0"}, :input]) == nil
  end

  test "lease events are recorded cluster-wide", %{nodes: [a, b, c]} do
    me = self()
    holder = Node.spawn(c, Home.Test.Holders, :holder, [me, {b, "cam0"}])
    assert_receive {:lease, ^holder, {:ok, _}}
    send(holder, :release)

    for n <- [a, b, c] do
      evs =
        eventually(fn ->
          case rpc(n, Activity, :since, [{b, "cam0"}, :lease, 10_000]) do
            [_, _] = evs -> evs
            _ -> nil
          end
        end)

      assert [:acquired, :released] = Enum.map(evs, & &1.event)
      assert Enum.all?(evs, &(&1.data.holder == holder and &1.data.holder_node == c))
      assert %{event: :released} = rpc(n, Activity, :last, [{b, "cam0"}, :lease])
    end
  end

  test "subscribe by kind or by capability, cluster-wide", %{nodes: [a, b, c]} do
    subscribe(c, :sensor)
    subscribe(a, {b, "temp0"})

    :ok = rpc(a, Activity, :emit, [{a, "temp0"}, :sensor, :reading, %{measure: :t, value: 21}])
    :ok = rpc(b, Activity, :emit, [{b, "temp0"}, :sensor, :reading, %{measure: :t, value: 19}])
    :ok = rpc(b, Activity, :emit, [{b, "pir0"}, :presence, :detected, %{sensor: :pir}])

    assert_receive {:activity, ^c, _, %{cap: {^a, "temp0"}, data: %{value: 21}}}
    assert_receive {:activity, ^c, _, %{cap: {^b, "temp0"}, data: %{value: 19}}}
    assert_receive {:activity, ^a, _, %{cap: {^b, "temp0"}, data: %{value: 19}}}
    refute_receive {:activity, _, _, %{kind: :presence}}, 200
    refute_received {:activity, ^a, _, %{cap: {^a, _}}}
  end

  test "since/3 windows and the bounded ring", %{nodes: [a, _b, c]} do
    cap = {a, "pir0"}
    [:ok, :ok, :ok] = rpc(a, ActivityProbe, :burst, [cap, :presence, :detected, 3, 0])
    Process.sleep(300)
    [:ok, :ok] = rpc(a, ActivityProbe, :burst, [cap, :presence, :cleared, 2, 0])

    eventually(fn -> length(rpc(c, Activity, :since, [cap, :presence, 10_000])) == 5 end)

    assert [:cleared, :cleared] =
             Enum.map(rpc(c, Activity, :since, [cap, :presence, 200]), & &1.event)

    all = rpc(c, Activity, :since, [cap, :presence, 10_000])
    assert Enum.map(all, & &1.event) == [:detected, :detected, :detected, :cleared, :cleared]
    assert all == Enum.sort_by(all, & &1.ts)

    # The ring keeps the last N per {cap, kind}.
    rpc(a, ActivityProbe, :burst, [cap, :presence, :detected, 2 * @ring, 0])

    eventually(fn ->
      match?(%{data: %{i: 32}}, rpc(c, Activity, :last, [cap, :presence]))
    end)

    ring = rpc(c, Activity, :since, [cap, :presence, 10_000])
    assert length(ring) == @ring
    assert Enum.map(ring, & &1.data.i) == Enum.to_list((@ring + 1)..(2 * @ring))
  end

  test "throttling coalesces bursts and keeps the final value; start/stop and leases never drop",
       %{nodes: [a, b, c]} do
    subscribe(c, {a, "input0"})
    subscribe(c, {a, "mic0"})
    subscribe(c, {a, "disp0"})

    # 40 touches over ~400 ms: at most one per 250 ms, first and last always delivered.
    results = rpc(a, ActivityProbe, :burst, [{a, "input0"}, :input, :touch, 40, 10])
    assert hd(results) == :ok and :throttled in results
    touches = collect(c, 600)
    assert_coalesced(touches, 40, 250)

    # :level and :frame at most one per second.
    Task.await_many([
      Task.async(fn ->
        rpc(a, ActivityProbe, :burst, [{a, "mic0"}, :audio_in, :level, 30, 40])
      end),
      Task.async(fn ->
        rpc(a, ActivityProbe, :burst, [{a, "disp0"}, :display, :frame, 30, 40])
      end)
    ])

    evs = collect(c, 1_500)
    assert_coalesced(for({t, %{event: :level} = e} <- evs, do: {t, e}), 30, 1_000)
    assert_coalesced(for({t, %{event: :frame} = e} <- evs, do: {t, e}), 30, 1_000)

    # Throttles are per {cap, kind, event}: other display events pass right through.
    assert [:ok, :ok, :ok] = rpc(a, ActivityProbe, :burst, [{a, "disp0"}, :display, :blank, 3, 0])
    assert [:ok] = rpc(a, ActivityProbe, :burst, [{a, "disp0"}, :display, :unblank, 1, 0])
    assert length(collect(c, 300)) == 4

    # Start/stop: never coalesced.
    assert Enum.all?(
             rpc(a, ActivityProbe, :burst, [{a, "mic0"}, :audio_in, :stream_started, 25, 0]),
             &(&1 == :ok)
           )

    started = collect(c, 300)
    assert Enum.map(started, &elem(&1, 1).data.i) == Enum.to_list(1..25)

    # An adapter can set its own rate: 0 turns throttling off for that call.
    assert Enum.all?(
             rpc(a, ActivityProbe, :burst, [{a, "input0"}, :input, :key, 10, 0, [throttle: 0]]),
             &(&1 == :ok)
           )

    assert length(collect(c, 300)) == 10

    # Lease events from rapid acquire/release cycles: every one recorded.
    for _ <- 1..div(@ring, 2) do
      {:ok, lease} = rpc(b, Home.Lease, :acquire, [{a, "spk0"}])
      :ok = rpc(b, Home.Lease, :release, [lease])
    end

    eventually(fn -> length(rpc(c, Activity, :since, [{a, "spk0"}, :lease, 10_000])) == @ring end)
    evs = rpc(c, Activity, :since, [{a, "spk0"}, :lease, 10_000])
    assert Enum.map(evs, & &1.event) == List.flatten(List.duplicate([:acquired, :released], 8))
  end

  # First event goes out at once, the last one (the final state) is never lost, and
  # deliveries are spaced by the interval.
  defp assert_coalesced(received, n, interval) do
    is = Enum.map(received, fn {_, ev} -> ev.data.i end)
    assert hd(is) == 1, "first of burst not delivered: #{inspect(is)}"
    assert List.last(is) == n, "final value of burst lost: #{inspect(is)}"
    assert is == Enum.sort(is)

    times = Enum.map(received, &elem(&1, 0))
    gaps = Enum.zip_with(times, tl(times), &(&2 - &1))
    assert Enum.all?(gaps, &(&1 >= interval - 50)), "gaps #{inspect(gaps)} < #{interval} ms"
  end

  test "a late-joining node gets the snapshot", %{nodes: [a, b, c]} do
    for i <- 1..5, do: :ok = rpc(a, Activity, :emit, [{a, "pir0"}, :presence, :detected, %{i: i}])
    :ok = rpc(b, Activity, :emit, [{b, "temp0"}, :sensor, :reading, %{value: 1}])
    eventually(fn -> rpc(b, Activity, :last, [{a, "pir0"}, :presence]) end)
    expected = Enum.sort(rpc(b, Activity, :snapshot))

    # (d may already be meshed through the test node by global's connect_all.)
    [{d, _}] = start_cluster("m6x", d: [capabilities: []])
    true = rpc(d, Node, :connect, [a])

    eventually(fn -> Enum.sort(rpc(d, Activity, :snapshot)) == expected end)
    assert %{data: %{value: 1}} = rpc(d, Activity, :last, [{b, "temp0"}, :sensor])
    assert length(rpc(d, Activity, :since, [{a, "pir0"}, :presence, 60_000])) == 5

    # Once meshed with everyone it is live like any other node.
    await_mesh([a, b, c, d])

    waiter =
      Task.async(fn ->
        rpc(d, ActivityProbe, :await_last, [{b, "temp0"}, :sensor, %{value: 2}])
      end)

    :ok = rpc(b, Activity, :emit, [{b, "temp0"}, :sensor, :reading, %{value: 2}])
    assert {:ok, us, _} = Task.await(waiter)
    assert us < 100_000
  end
end
