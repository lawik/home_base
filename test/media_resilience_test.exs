defmodule Home.MediaResilienceTest do
  # Media sessions over an impaired network (`Home.Test.LossyRelay` between source and
  # sink), RTCP stats, keyframe requests, playout trimming, and sinks added to / removed
  # from running sessions.
  use Home.Test.ClusterCase, async: false

  alias Home.Adapters.Audio.{CaptureSpeaker, SynthMic}
  alias Home.Adapters.Video.SynthCamera
  alias Home.Media.Session
  alias Home.Test.{LossyRelay, MediaHelpers, Render, VideoHelpers}

  @moduletag timeout: 180_000

  @video {320, 240}

  setup do
    me = self()

    mic = %{
      id: "mic0",
      kind: :audio_in,
      availability: :on_request,
      adapter: SynthMic,
      meta: %{notify: me, click_every: 300}
    }

    cam = %{
      id: "cam0",
      kind: :video_in,
      availability: :on_request,
      adapter: SynthCamera,
      meta: %{notify: me, w: 320, h: 240, fps: 30}
    }

    speaker = &%{id: &1, kind: :audio_out, adapter: CaptureSpeaker, meta: %{notify: me}}
    display = &%{id: &1, kind: :display, adapter: Home.Adapters.Display, meta: %{w: 320, h: 240}}

    [{a, _}, {b, _}, {c, _}] =
      start_cluster("m7r",
        a: [capabilities: [mic, cam], media: [ports: 41_700..41_719]],
        b: [capabilities: [speaker.("spk0"), display.("disp0")], media: [ports: 41_720..41_739]],
        c: [capabilities: [speaker.("spk1"), display.("disp1")], media: [ports: 41_740..41_759]]
      )

    for n <- [a, b, c] do
      eventually(fn -> length(rpc(n, Home.Registry, :list, [])) == 6 end)
      rpc(n, MediaHelpers, :preload)
    end

    %{a: a, b: b, c: c}
  end

  describe "packet loss" do
    test "audio: RTCP reports loss and jitter, NACKs repair most of it", ctx do
      %{a: a, b: b, c: c} = ctx
      spk = {b, "spk0"}

      results =
        for feedback <- [[], [:nack]] do
          route = {LossyRelay, :route, [[loss: 0.05, jitter: 8, seed: {7, 8, 9}]]}
          {owner, session} = intercom(c, {a, "mic0"}, spk, route: route, feedback: feedback)
          assert_receive {:capture_started, ^spk}, 5_000

          Process.sleep(4_000)
          stats = rpc(c, Session, :stats, [session])
          %{destinations: [{_ip, port}]} = rpc(c, Session, :info, [session])
          relay = rpc(c, LossyRelay, :stats, [port])
          stop_intercom(owner)

          sink = stats.sinks[spk]
          report = stats.source.receivers[spk]

          IO.puts(
            "\naudio, 5% loss, feedback #{inspect(feedback)}: relay dropped #{relay.dropped} " <>
              "of #{relay.dropped + relay.forwarded}; sink lost #{sink.lost} of " <>
              "#{sink.expected} (#{sink.nacked} NACKed, #{sink.recovered} recovered), " <>
              "jitter #{sink.jitter_ms} ms; source: RR fraction_lost #{report.fraction_lost}, " <>
              "lost #{report.lost}, jitter #{report.jitter_ms} ms, rtt #{report.rtt_ms} ms, " <>
              "retransmitted #{stats.source.retransmitted}"
          )

          assert relay.dropped > 0
          assert sink.packets > 100
          assert report.jitter_ms > 0 and sink.jitter_ms > 0
          assert is_float(report.rtt_ms) and report.rtt_ms < 100
          {feedback, sink, stats.source}
        end

      [{[], plain, plain_source}, {[:nack], nacked, nacked_source}] = results

      # Without feedback the loss shows in both ends' counts; with NACK most of it is
      # resent and recovered before the jitter buffer gives up on it.
      assert plain.lost > 0 and plain.nacked == 0 and plain_source.retransmitted == 0
      assert nacked.nacked > 0 and nacked.recovered > 0
      assert nacked_source.retransmitted > 0
      assert nacked.lost < plain.lost
    end

    test "video: a keyframe request ends the freeze after a loss burst", ctx do
      %{a: a, b: b, c: c} = ctx

      recoveries =
        for feedback <- [[], [:pli], [:nack, :pli]] do
          route = {LossyRelay, :route, [[]]}

          {:ok, video} =
            rpc(c, Home.Render, :show_video, [
              {a, "cam0"},
              [on: {b, "disp0"}, gop_size: 90, feedback: feedback, route: route]
            ])

          assert_receive {:home_hw, "cam0", :on}, 5_000
          media = rpc(c, Home.Render.Video, :media, [video])
          %{destinations: [{_ip, port}]} = rpc(c, Session, :info, [media])

          Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 4_000])
          Process.sleep(700)
          blackout_end = :os.system_time(:microsecond) + 200_000
          :ok = rpc(c, LossyRelay, :configure, [port, [blackout: 200]])
          shown = collect_shown()

          stats = rpc(c, Session, :stats, [media])
          :ok = rpc(c, Home.Render, :stop, [video])
          assert_receive {:home_hw, "cam0", :off}, 5_000

          for ref <- [{a, "cam0"}, {b, "disp0"}],
              do: eventually(fn -> match?(%{status: :idle}, cap(c, ref)) end)

          flush_frames()

          # Time from the end of the blackout to the first frame captured after it on
          # screen; frames resent by NACK from during the blackout don't count.
          {n_first, t_first} =
            shown |> Enum.filter(fn {_n, t} -> t > blackout_end end) |> Enum.min_by(&elem(&1, 1))

          fresh =
            Enum.find(Enum.sort_by(shown, &elem(&1, 1)), fn {n, t} ->
              t > blackout_end and n > n_first + 3
            end)

          recovery = (t_first - blackout_end) / 1_000
          sink = stats.sinks[{b, "disp0"}]

          IO.puts(
            "\nvideo, 200 ms blackout, feedback #{inspect(feedback)}: first frame after " <>
              "#{Float.round(recovery, 1)} ms; #{length(shown)} frames shown in 4 s, " <>
              "keyframe requests #{sink.keyframe_requests}, forced " <>
              "#{stats.source.keyframes_forced}, recovered by NACK #{sink.recovered}" <>
              if(fresh, do: "", else: " (never caught up)")
          )

          {feedback, recovery, stats}
        end

      [{[], plain, plain_stats}, {[:pli], pli, pli_stats}, {[:nack, :pli], _, _}] = recoveries

      # With 3 s between keyframes the plain stream waits for the next one; a PLI gets
      # one within a round trip and a frame.
      assert plain_stats.source.keyframes_forced == 0
      assert pli_stats.source.keyframes_forced > 0
      assert pli < 300
      assert pli < plain
    end
  end

  test "audio playout queue: a burst is trimmed back instead of becoming latency", ctx do
    %{a: a, b: b, c: c} = ctx
    spk = {b, "spk0"}

    results =
      for playout <- [false, 20] do
        route = {LossyRelay, :route, [[]]}
        {owner, session} = intercom(c, {a, "mic0"}, spk, route: route, playout: playout)
        assert_receive {:capture_started, ^spk}, 5_000

        # The playout queue ahead of each click: a click's latency is this plus the
        # (fixed) network and codec delay.
        startup = queued(spk, 1_200)
        before = queued(spk, 1_500)
        %{destinations: [{_ip, port}]} = rpc(c, Session, :info, [session])
        :ok = rpc(c, LossyRelay, :configure, [port, [stall: 400]])
        during = queued(spk, 1_500)
        settled = queued(spk, 2_000)
        stats = rpc(c, Session, :stats, [session])
        stop_intercom(owner)

        IO.puts(
          "\naudio, 400 ms stall then burst, playout #{inspect(playout)}: playout queue " <>
            "#{inspect(startup, charlists: :as_lists)} ms at the start, median before #{median(before)} ms, in the 1.5 s after #{inspect(during, charlists: :as_lists)} ms, " <>
            "settled #{median(settled)} ms (#{inspect(stats.sinks[spk][:playout])})"
        )

        {playout, median(before), median(settled)}
      end

    [{false, _, untrimmed}, {20, before, trimmed}] = results

    # Without trimming the burst stays in the queue for good; with it the queue is
    # back to where it was.
    assert untrimmed > 300
    assert trimmed < before + 25
  end

  describe "sinks on a running session" do
    test "add a speaker, then remove the first one", ctx do
      %{a: a, b: b, c: c} = ctx
      {owner, session} = intercom(c, {a, "mic0"}, {b, "spk0"})
      assert_receive {:capture_started, {^b, "spk0"}}, 5_000
      mic_source = rpc(c, Session, :info, [session]).pipelines |> hd()

      {:ok, lease} = rpc(c, Home.Lease, :acquire, [{c, "spk1"}, [for: owner]])
      assert :ok = rpc(c, Session, :add_sink, [session, lease])
      assert {:error, :already_a_sink} = rpc(c, Session, :add_sink, [session, lease])
      assert_receive {:capture_started, {^c, "spk1"}}, 5_000
      assert %{sinks: [{^b, "spk0"}, {^c, "spk1"}]} = rpc(c, Session, :info, [session])

      {clicks, onsets} = collect(1_500)
      assert length(latencies(clicks, Map.get(onsets, {c, "spk1"}, []))) >= 3

      assert :ok = rpc(c, Session, :remove_sink, [session, {b, "spk0"}])
      eventually(fn -> match?(%{status: :idle}, cap(c, {b, "spk0"})) end)
      eventually(fn -> rpc(b, MediaHelpers, :media_children) == 0 end)

      flush_onsets()
      {clicks, onsets} = collect(1_500)
      assert Map.get(onsets, {b, "spk0"}, []) == []
      assert length(latencies(clicks, Map.get(onsets, {c, "spk1"}, []))) >= 3

      # The mic and its pipeline kept running throughout.
      assert rpc(c, Session, :info, [session]).pipelines |> hd() == mic_source
      refute_received {:home_hw, "mic0", :off}

      assert {:error, :last_sink} = rpc(c, Session, :remove_sink, [session, {c, "spk1"}])
      assert {:error, :not_a_sink} = rpc(c, Session, :remove_sink, [session, {b, "spk0"}])
      stop_intercom(owner)
    end

    test "a video moves to another display without restarting the camera", ctx do
      %{a: a, b: b, c: c} = ctx
      {:ok, video} = rpc(c, Home.Render, :show_video, [{a, "cam0"}, [on: {b, "disp0"}]])
      assert_receive {:home_hw, "cam0", :on}, 5_000
      Node.spawn(b, VideoHelpers, :watch, [self(), "disp0", @video, 500])
      assert length(collect_shown()) > 5

      Node.spawn(c, VideoHelpers, :watch, [self(), "disp1", @video, 1_500])
      Process.sleep(100)
      t0 = :os.system_time(:microsecond)
      assert :ok = rpc(c, Home.Render, :move, [video, [to: {c, "disp1"}]])
      t_moved = :os.system_time(:microsecond)
      shown = collect_shown()
      assert length(shown) > 15
      first = shown |> Enum.map(&elem(&1, 1)) |> Enum.min()

      IO.puts(
        "\nvideo move B -> C: move/2 took #{(t_moved - t0) / 1_000} ms, first frame on C " <>
          "#{(first - t0) / 1_000} ms after it was called"
      )

      assert rpc(c, Home.Render, :target, [video]) == {c, "disp1"}
      assert rpc(c, Render, :shown, ["disp1"]) == video
      eventually(fn -> rpc(b, Render, :shown, ["disp0"]) == nil end)
      eventually(fn -> match?(%{status: :idle}, cap(c, {b, "disp0"})) end)
      eventually(fn -> rpc(b, MediaHelpers, :media_children) == 0 end)
      refute_received {:home_hw, "cam0", :off}

      :ok = rpc(c, Home.Render, :stop, [video])
      assert_receive {:home_hw, "cam0", :off}, 5_000
      eventually(fn -> match?(%{status: :idle}, cap(c, {c, "disp1"})) end)
    end
  end

  ## Helpers

  defp intercom(node, source, sinks, opts \\ []) do
    # A previous session's leases are released just after it stops.
    for ref <- [source | List.wrap(sinks)],
        do: eventually(fn -> match?(%{status: :idle}, cap(node, ref)) end)

    owner = Node.spawn(node, MediaHelpers, :intercom, [self(), source, sinks, opts])
    assert_receive {:session, ^owner, {:ok, session}}, 10_000
    {owner, session}
  end

  defp stop_intercom(owner) do
    send(owner, :stop)
    assert_receive {:stopped, ^owner}, 5_000
    assert_receive {:home_hw, "mic0", :off}, 5_000
    flush_onsets()
  end

  defp cap(node, ref), do: Enum.find(rpc(node, Home.Registry, :list, []), &(&1.ref == ref))

  defp collect_shown(shown \\ %{}) do
    receive do
      {:shown, _cap, n, t} -> collect_shown(Map.put_new(shown, n, t))
      {:watch_done, _cap, _polls} -> Map.to_list(shown)
    after
      10_000 -> flunk("watcher did not finish")
    end
  end

  defp flush_frames do
    receive do
      {:synth_frame, _, _, _} -> flush_frames()
    after
      0 -> :ok
    end
  end

  defp flush_onsets do
    receive do
      {:capture_onset, _, _, _} -> flush_onsets()
      {:synth_click, _, _} -> flush_onsets()
      {:capture_started, _} -> flush_onsets()
      {:capture_stats, _, _} -> flush_onsets()
    after
      0 -> :ok
    end
  end

  # Playout queue (ms) ahead of each click heard on `cap` in the next `ms`.
  defp queued(cap, ms) do
    {_clicks, onsets} = collect(ms)
    for {_t, queued} <- onsets |> Map.get(cap, []) |> Enum.sort(), do: div(queued, 1_000)
  end

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

  # Each onset belongs to the latest click sent before it; latencies in ms.
  defp latencies(clicks, onsets) do
    for {t, _queued} <- Enum.sort(onsets),
        click = clicks |> Enum.filter(&(&1 <= t)) |> List.last(),
        click != nil,
        do: (t - click) / 1_000
  end

  defp median([]), do: nil
  defp median(values), do: Enum.at(Enum.sort(values), div(length(values), 2))
end
