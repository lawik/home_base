defmodule Home.MediaMixerTest do
  use Home.Test.ClusterCase, async: false

  alias Home.Adapters.Audio.{CaptureSpeaker, Mixer, SynthMic}
  alias Home.Test.MediaHelpers

  @moduletag timeout: 120_000

  defp mic(id, notify, every) do
    %{
      id: id,
      kind: :audio_in,
      availability: :on_request,
      adapter: SynthMic,
      meta: %{notify: notify, click_every: every}
    }
  end

  setup do
    me = self()
    cookie = Node.get_cookie()
    Node.set_cookie(:m2_media_test)
    on_exit(fn -> Node.set_cookie(cookie) end)

    speaker = %{
      id: "spk0",
      kind: :audio_out,
      adapter: {Mixer, output: CaptureSpeaker},
      meta: %{notify: me}
    }

    [{a, _}, {b, _}, {c, _}] =
      start_cluster("m2x",
        a: [capabilities: [mic("mic0", me, 400)], media: [ports: 41_060..41_079]],
        b: [capabilities: [speaker], media: [ports: 41_080..41_099]],
        c: [capabilities: [mic("mic1", me, 400)], media: [ports: 41_100..41_119]]
      )

    for n <- [a, b, c] do
      eventually(fn -> length(rpc(n, Home.Registry, :list, [])) == 3 end)
      rpc(n, MediaHelpers, :preload)
    end

    %{a: a, b: b, c: c}
  end

  test "two sessions share a mixed speaker; each one can leave without the other", ctx do
    %{a: a, b: b, c: c} = ctx
    me = self()
    spk = {b, "spk0"}

    one = Node.spawn(a, MediaHelpers, :intercom, [me, {a, "mic0"}, spk])
    assert_receive {:session, ^one, {:ok, _}}, 10_000
    lat = latencies({a, "mic0"}, spk, 2_500)
    report("A -> B via mixer", lat)
    assert length(lat) >= 4
    assert p95(lat) <= 150

    two = Node.spawn(c, MediaHelpers, :intercom, [me, {c, "mic1"}, spk])
    assert_receive {:session, ^two, {:ok, _}}, 10_000
    assert [%{leases: 2}] = rpc(a, Home.Registry, :list, [[kind: :audio_out]])
    # Both mics feed the speaker: its mixer has two inputs.
    eventually(fn -> mixer_inputs(b) == 2 end)

    send(one, :stop)
    assert_receive {:stopped, ^one}
    assert_receive {:home_hw, "mic0", :off}
    eventually(fn -> mixer_inputs(b) == 1 end)

    flush()
    lat = latencies({c, "mic1"}, spk, 2_000)
    report("C -> B via mixer, after A left", lat)
    assert length(lat) >= 3
    assert p95(lat) <= 150

    send(two, :stop)
    assert_receive {:stopped, ^two}
    assert_receive {:home_hw, "mic1", :off}
    eventually(fn -> mixer_inputs(b) == 0 end)
  end

  test "the mixer pipeline dies: it starts again and the session plays on", ctx do
    %{a: a, b: b} = ctx
    me = self()
    spk = {b, "spk0"}
    {:ok, server} = rpc(b, Home.Registry, :whereis, [spk])

    one = Node.spawn(a, MediaHelpers, :intercom, [me, {a, "mic0"}, spk])
    assert_receive {:session, ^one, {:ok, session}}, 10_000
    assert length(latencies({a, "mic0"}, spk, 1_500)) >= 2
    mixer = rpc(b, MediaHelpers, :mixer, [spk])

    Process.exit(mixer, :kill)
    eventually(fn -> rpc(b, MediaHelpers, :mixer, [spk]) not in [nil, mixer] end)
    eventually(fn -> mixer_inputs(b) == 1 end)

    flush()
    lat = latencies({a, "mic0"}, spk, 2_000)
    report("A -> B via a restarted mixer", lat)
    assert length(lat) >= 4
    assert p95(lat) <= 150

    # Nothing else noticed: same capability server, same lease, same session.
    assert {:ok, ^server} = rpc(b, Home.Registry, :whereis, [spk])
    assert [%{leases: 1}] = rpc(a, Home.Registry, :list, [[kind: :audio_out]])
    assert rpc(a, Process, :alive?, [session])
    refute_received {:session_down, ^one, _}

    send(one, :stop)
    assert_receive {:stopped, ^one}
  end

  defp mixer_inputs(node) do
    rpc(node, MediaHelpers, :mixer_inputs, [{node, "spk0"}])
  end

  defp flush do
    receive do
      {:synth_click, _, _} -> flush()
      {:capture_onset, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp latencies(mic, spk, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    {clicks, onsets} = collect(mic, spk, deadline, [], [])

    for t <- onsets,
        click = clicks |> Enum.filter(&(&1 <= t)) |> List.last(),
        click != nil,
        do: (t - click) / 1_000
  end

  defp collect(mic, spk, deadline, clicks, onsets) do
    left = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:synth_click, ^mic, t} -> collect(mic, spk, deadline, [t | clicks], onsets)
      {:capture_onset, ^spk, t, _} -> collect(mic, spk, deadline, clicks, [t | onsets])
    after
      left -> {Enum.sort(clicks), Enum.sort(onsets)}
    end
  end

  defp p95(values), do: percentile(values, 0.95)

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, round(p * (length(sorted) - 1))))
  end

  defp report(label, lat) do
    IO.puts(
      "\n#{label}: #{length(lat)} clicks, end-to-end latency median #{percentile(lat, 0.5)} ms, " <>
        "p95 #{percentile(lat, 0.95)} ms, max #{Enum.max(lat, fn -> nil end)} ms"
    )
  end
end
