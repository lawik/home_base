defmodule Home.PortAudioLoopbackTest do
  # Real PortAudio devices through the ALSA loopback card (`modprobe snd-aloop`), which
  # this test expects as PortAudio devices 0 ("Loopback: PCM (hw:0,0)", playback in) and
  # 1 ("hw:0,1", capture out). Excluded by default; run with `mix test --only portaudio`.
  #
  #   synth clicks -> loopback -> [PortAudioIn mic on A] -> Opus/RTP -> [PortAudioOut on B]
  #   -> loopback -> capture -> onsets
  #
  # The two extra loopback hops (feeding the mic, capturing the speaker) are measured on
  # their own first and subtracted.
  use Home.Test.ClusterCase, async: false

  alias Home.Adapters.Audio.{PortAudioIn, PortAudioOut}
  alias Home.Test.{Chain, MediaHelpers}

  @moduletag :portaudio
  @moduletag timeout: 120_000

  setup do
    cookie = Node.get_cookie()
    Node.set_cookie(:m2_media_test)
    on_exit(fn -> Node.set_cookie(cookie) end)

    mic = %{
      id: "mic0",
      kind: :audio_in,
      availability: :on_request,
      adapter: PortAudioIn,
      meta: %{device_id: 1}
    }

    spk = %{id: "spk0", kind: :audio_out, adapter: PortAudioOut, meta: %{device_id: 0}}

    [{a, _}, {b, _}] =
      start_cluster("m2pa",
        a: [capabilities: [mic], media: [ports: 41_120..41_139]],
        b: [capabilities: [spk], media: [ports: 41_140..41_159]]
      )

    for n <- [a, b] do
      eventually(fn -> length(rpc(n, Home.Registry, :list, [])) == 2 end)
      rpc(n, MediaHelpers, :preload)
    end

    %{a: a, b: b}
  end

  test "intercom between PortAudio devices over the loopback card", %{a: a, b: b} do
    me = self()

    # Baseline: the two extra hops alone, synth -> loopback -> capture.
    {:ok, feeder} = rpc(a, Chain, :start, [[feeder(me), player(0)]])
    {:ok, meter} = rpc(b, Chain, :start, [[recorder(1), meter(me)]])
    base = collect(2_500)
    for p <- [meter, feeder], do: Membrane.Pipeline.terminate(p)
    report("loopback only (feeder -> meter)", base)

    # Loopback substreams pair up in open order: the feeder takes playback 0 (heard by the
    # mic on capture 0), the speaker playback 1 (heard by the meter on capture 1).
    {:ok, feeder} = rpc(a, Chain, :start, [[feeder(me), player(0)]])
    Process.sleep(300)
    owner = Node.spawn(b, MediaHelpers, :intercom, [me, {a, "mic0"}, {b, "spk0"}])
    assert_receive {:session, ^owner, {:ok, _}}, 10_000
    Process.sleep(300)
    {:ok, meter} = rpc(b, Chain, :start, [[recorder(1), meter(me)]])
    flush()

    lat = collect(4_000)
    report("PortAudio mic on A -> speaker on B, plus the loopback hops", lat)

    IO.puts(
      "  session alone, estimated: #{Float.round(pct(lat, 0.5) - pct(base, 0.5), 1)} ms (median difference)"
    )

    assert length(base) >= 3 and length(lat) >= 5
    assert pct(lat, 0.5) - pct(base, 0.5) <= 150

    send(owner, :stop)
    assert_receive {:stopped, ^owner}
    for p <- [meter, feeder], do: Membrane.Pipeline.terminate(p)
  end

  defp feeder(me), do: %Home.Media.SynthSource{notify: me, cap: :feeder, click_every: 400}
  defp player(device), do: %Membrane.PortAudio.Sink{device_id: device, latency: :low}
  defp meter(me), do: %Home.Media.CaptureSink{notify: me, cap: :meter}

  defp recorder(device) do
    %Membrane.PortAudio.Source{device_id: device, channels: 1, sample_rate: 48_000, latency: :low}
  end

  defp report(label, lat) do
    IO.puts(
      "\n#{label}: #{length(lat)} clicks, median #{pct(lat, 0.5)} ms, p95 #{pct(lat, 0.95)} ms"
    )
  end

  defp flush do
    receive do
      {:synth_click, _, _} -> flush()
      {:capture_onset, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp collect(ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    collect(deadline, [], [])
  end

  defp collect(deadline, clicks, onsets) do
    left = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:synth_click, :feeder, t} ->
        collect(deadline, [t | clicks], onsets)

      {:capture_onset, :meter, t, _} ->
        collect(deadline, clicks, [t | onsets])
    after
      left ->
        clicks = Enum.sort(clicks)

        for t <- Enum.sort(onsets),
            c = clicks |> Enum.filter(&(&1 <= t)) |> List.last(),
            c != nil,
            do: (t - c) / 1_000
    end
  end

  defp pct([], _), do: nil
  defp pct(values, p), do: Enum.at(Enum.sort(values), round(p * (length(values) - 1)))
end
