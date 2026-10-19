defmodule Home.MediaSessionTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Adapters.Audio.{CaptureSpeaker, SynthMic}
  alias Home.Test.MediaHelpers

  @moduletag timeout: 120_000

  defp mic(notify) do
    %{
      id: "mic0",
      kind: :audio_in,
      availability: :on_request,
      adapter: SynthMic,
      meta: %{notify: notify, click_every: 300}
    }
  end

  defp speaker(id, notify),
    do: %{id: id, kind: :audio_out, adapter: CaptureSpeaker, meta: %{notify: notify}}

  setup do
    me = self()

    # Own cookie: other suites on this host may run epmd-discovered clusters with a prefix
    # that matches these peers' names.
    cookie = Node.get_cookie()
    Node.set_cookie(:m2_media_test)
    on_exit(fn -> Node.set_cookie(cookie) end)

    [{a, _}, {b, bpeer}, {c, _}] =
      start_cluster("m2",
        a: [capabilities: [mic(me)], media: [ports: 41_000..41_019]],
        b: [capabilities: [speaker("spk0", me)], media: [ports: 41_020..41_039]],
        c: [capabilities: [speaker("spk1", me)], media: [ports: 41_040..41_059]]
      )

    # Wait until every node sees every capability.
    for n <- [a, b, c] do
      eventually(fn -> length(rpc(n, Home.Registry, :list, [])) == 3 end)
      rpc(n, MediaHelpers, :preload)
    end

    %{a: a, b: b, c: c, bpeer: bpeer}
  end

  test "intercom from an on-request mic on A to a speaker on B, started from C", ctx do
    %{a: a, b: b, c: c} = ctx
    me = self()

    owner = Node.spawn(c, MediaHelpers, :intercom, [me, {a, "mic0"}, {b, "spk0"}])
    assert_receive {:session, ^owner, {:ok, session}}, 10_000
    assert node(session) == c
    assert_receive {:home_hw, "mic0", :on}

    # Both leases are now held by the session.
    for {n, kind} <- [{a, :audio_in}, {b, :audio_out}] do
      assert [%{status: :leased}] = rpc(c, Home.Registry, :list, [[kind: kind, node: n]])
    end

    assert %{destinations: [{{127, 0, 0, 1}, port}]} =
             rpc(c, Home.Media.Session, :info, [session])

    assert port in 41_020..41_039

    assert_receive {:capture_started, {^b, "spk0"}}, 5_000
    latencies = measure({b, "spk0"}, 3_000)
    report("A -> B", latencies)

    assert length(latencies) >= 6
    assert p95(latencies) <= 150

    # Levels and stream events reach the activity store on every node.
    eventually(fn -> rpc(c, Home.Activity, :last, [{b, "spk0"}, :audio_out]) end)
    eventually(fn -> rpc(c, Home.Activity, :last, [{a, "mic0"}, :audio_in]) end)

    # Normal stop releases both leases and turns the mic off.
    send(owner, :stop)
    assert_receive {:stopped, ^owner}
    assert_receive {:home_hw, "mic0", :off}

    for {n, kind} <- [{a, :audio_in}, {b, :audio_out}] do
      eventually(fn ->
        match?([%{status: :idle}], rpc(c, Home.Registry, :list, [[kind: kind, node: n]]))
      end)
    end

    eventually(fn -> Enum.all?([a, b, c], &(rpc(&1, MediaHelpers, :media_children) == 0)) end)
    assert rpc(a, Home.Activity, :last, [{a, "mic0"}, :audio_in]).event == :stream_stopped
  end

  test "sink node dies mid-session: session tears down and the mic closes", ctx do
    %{a: a, b: b, c: c, bpeer: bpeer} = ctx
    me = self()

    owner = Node.spawn(c, MediaHelpers, :intercom, [me, {a, "mic0"}, {b, "spk0"}])
    assert_receive {:session, ^owner, {:ok, _session}}, 10_000
    assert_receive {:home_hw, "mic0", :on}
    assert_receive {:capture_onset, {^b, "spk0"}, _, _}, 5_000

    stop(bpeer)

    assert_receive {:session_down, ^owner, {:shutdown, {:down, _what, _reason}}}, 5_000
    assert_receive {:home_hw, "mic0", :off}, 5_000

    eventually(fn ->
      match?(
        [%{status: :idle, hardware: :off}],
        rpc(a, Home.Registry, :list, [[kind: :audio_in]])
      )
    end)

    # The source pipeline on A and the session on C are gone.
    eventually(fn -> rpc(a, MediaHelpers, :media_children) == 0 end)
    eventually(fn -> rpc(c, MediaHelpers, :media_children) == 0 end)
  end

  test "fan-out: one mic, one encoder, two speakers", ctx do
    %{a: a, b: b, c: c} = ctx
    me = self()

    owner = Node.spawn(a, MediaHelpers, :intercom, [me, {a, "mic0"}, [{b, "spk0"}, {c, "spk1"}]])
    assert_receive {:session, ^owner, {:ok, session}}, 10_000
    assert %{destinations: [_, _]} = rpc(a, Home.Media.Session, :info, [session])

    assert_receive {:capture_started, {^b, "spk0"}}, 5_000
    assert_receive {:capture_started, {^c, "spk1"}}, 5_000

    {clicks, onsets} = collect(2_000)
    lat_b = latencies(clicks, Map.get(onsets, {b, "spk0"}, []))
    lat_c = latencies(clicks, Map.get(onsets, {c, "spk1"}, []))
    report("A -> B (fan-out)", lat_b)
    report("A -> C (fan-out)", lat_c)
    assert length(lat_b) >= 4 and length(lat_c) >= 4
    assert p95(lat_b) <= 150 and p95(lat_c) <= 150

    send(owner, :stop)
    assert_receive {:stopped, ^owner}
    assert_receive {:home_hw, "mic0", :off}
  end

  test "a session that can't start leaves no pipelines and releases the leases", ctx do
    %{a: a, b: b} = ctx
    me = self()

    owner = Node.spawn(a, MediaHelpers, :intercom, [me, {a, "mic0"}, {b, "spk0"}, [codec: :pcm]])
    assert_receive {:session, ^owner, {:error, :unsupported_codec}}
    assert_receive {:home_hw, "mic0", :on}
    # The owner still holds its leases until it exits.
    Process.exit(owner, :kill)
    assert_receive {:home_hw, "mic0", :off}
    assert rpc(a, MediaHelpers, :media_children) == 0
  end

  ## Measuring

  defp measure(cap, ms) do
    {clicks, onsets} = collect(ms)
    latencies(clicks, Map.get(onsets, cap, []))
  end

  # Gather clicks sent by the synthetic mic and onsets heard by the speakers for `ms`.
  defp collect(ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    collect(deadline, [], %{})
  end

  defp collect(deadline, clicks, onsets) do
    left = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:synth_click, _, t} ->
        collect(deadline, [t | clicks], onsets)

      {:capture_onset, cap, t, queued} ->
        collect(deadline, clicks, Map.update(onsets, cap, [{t, queued}], &[{t, queued} | &1]))
    after
      left -> {Enum.sort(clicks), onsets}
    end
  end

  # Each onset belongs to the latest click sent before it. `{latency, queued}` in ms, where
  # `queued` is the part spent in the speaker's playout queue.
  defp latencies(clicks, onsets) do
    for {t, queued} <- Enum.sort(onsets),
        click = clicks |> Enum.filter(&(&1 <= t)) |> List.last(),
        click != nil,
        do: {(t - click) / 1_000, queued / 1_000}
  end

  defp p95(latencies), do: latencies |> Enum.map(&elem(&1, 0)) |> percentile(0.95)

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, round(p * (length(sorted) - 1))))
  end

  defp report(label, latencies) do
    totals = Enum.map(latencies, &elem(&1, 0))
    queued = Enum.map(latencies, &elem(&1, 1))

    IO.puts(
      "\n#{label}: #{length(totals)} clicks, end-to-end latency median #{percentile(totals, 0.5)} ms, " <>
        "p95 #{percentile(totals, 0.95)} ms, max #{Enum.max(totals, fn -> nil end)} ms " <>
        "(of which playout queue median #{percentile(queued, 0.5)} ms)"
    )
  end
end
