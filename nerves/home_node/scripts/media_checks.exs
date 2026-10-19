# Media checks across the qemu NAT, used by demo.exs (run as host node nv1, the caller of
# every session). See README "Media across qemu NAT".
#
# Timestamps: the guest's synthetic adapters report through HomeNode.Probe in the guest's
# wall clock; nv1's in the host's. `clock_offset/1` estimates guest - host from the
# fastest of 20 :erpc round trips, and guest times are shifted by it. Its error is at most
# half that round trip (printed).

defmodule DemoMedia.App do
  @moduledoc false
  # Scene-forwarded to the guest's display: red, blue after an odd number of presses on the
  # green button in the top-left corner.
  use Emerge

  @impl Viewport
  def mount(opts) do
    config = %Emerge.Config{
      runtime: Keyword.get(opts, :runtime, []),
      assets: [otp_app: :home_base]
    }

    {:ok, %{presses: 0, test: opts[:test]}, config}
  end

  @impl Viewport
  def render(%{presses: presses}) do
    bg = if rem(presses, 2) == 0, do: color_rgb(255, 0, 0), else: color_rgb(0, 0, 255)

    column([width(fill()), height(fill()), Background.color(bg)], [
      Input.button(
        [
          width(px(40)),
          height(px(40)),
          key(:inc),
          Background.color(color_rgb(0, 255, 0)),
          Event.on_press(:inc)
        ],
        none()
      )
    ])
  end

  @impl Viewport
  def handle_info(:inc, state) do
    if state.test, do: send(state.test, {:app_pressed, :os.system_time(:microsecond)})
    {:noreply, Viewport.rerender(%{state | presses: state.presses + 1})}
  end
end

defmodule DemoMedia do
  alias Home.{Lease, Media}
  alias Home.Render.Compositor

  ## Clocks and code

  def clock_offset(guest) do
    samples =
      for _ <- 1..20 do
        t0 = :os.system_time(:microsecond)
        g = :erpc.call(guest, :os, :system_time, [:microsecond])
        t1 = :os.system_time(:microsecond)
        {t1 - t0, g - div(t0 + t1, 2)}
      end

    {rtt, offset} = Enum.min(samples)
    %{offset_us: offset, rtt_us: rtt}
  end

  @doc """
  Load every module of `node`'s loaded applications, as an embedded-mode release does at
  boot. Otherwise the first packets pay for loading the RTP/Opus/H.264 modules, which ends
  up as permanent playout delay (`Home.Test.MediaHelpers.preload/0` does the same on peers).
  """
  def preload(node) do
    for {app, _, _} <- :erpc.call(node, Application, :loaded_applications, []),
        {:ok, mods} = :erpc.call(node, :application, :get_key, [app, :modules]) do
      :erpc.call(node, :code, :ensure_modules_loaded, [mods], 60_000)
    end

    :ok
  end

  ## Audio

  @doc """
  An Opus session from `source` to `sink`, both `{node, cap_id}`, started and owned here.
  Collects clicks and onsets for `ms` and returns latencies in ms, with clicks/onsets from
  `guest` shifted by `offset_us`.
  """
  def audio(source, sink, guest, offset_us, ms) do
    flush()
    {:ok, mic} = Lease.acquire(source, purpose: "home_node demo")
    {:ok, spk} = Lease.acquire(sink, purpose: "home_node demo")
    {:ok, session} = Media.Session.start(source: mic, sink: spk, codec: :opus)
    info = Media.Session.info(session)
    IO.puts("   session on #{node()}: #{fmt(source)} -> #{fmt(sink)}")
    IO.puts("   sink advertised #{inspect(info.destinations)}")

    receive do
      {:capture_started, ^sink} -> :ok
    after
      10_000 -> Demo.fail!("no audio reached #{fmt(sink)} within 10 s")
    end

    {clicks, onsets} = collect_audio(source, sink, guest, offset_us, ms)
    :ok = Media.Session.stop(session)
    latencies(clicks, onsets)
  end

  defp collect_audio(source, sink, guest, offset, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    collect_audio(source, sink, guest, offset, deadline, [], [])
  end

  defp collect_audio(source, sink, guest, offset, deadline, clicks, onsets) do
    left = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:synth_click, ^source, t} ->
        t = host_time(source, t, guest, offset)
        collect_audio(source, sink, guest, offset, deadline, [t | clicks], onsets)

      {:capture_onset, ^sink, t, _queued} ->
        t = host_time(sink, t, guest, offset)
        collect_audio(source, sink, guest, offset, deadline, clicks, [t | onsets])
    after
      left -> {Enum.sort(clicks), Enum.sort(onsets)}
    end
  end

  # Each onset belongs to the latest click before it.
  defp latencies(clicks, onsets) do
    for t <- onsets,
        click = clicks |> Enum.filter(&(&1 <= t)) |> List.last(),
        click != nil,
        do: (t - click) / 1_000
  end

  ## Video: camera on the guest -> headless display on this node

  def video(cam, disp, guest, offset_us, ms) do
    flush()
    {:ok, video} = Home.Render.show_video(cam, on: disp)
    comp = compositor(disp)
    me = self()
    size = cam_size(cam)
    deadline = System.monotonic_time(:millisecond) + ms
    watcher = spawn_link(fn -> watch(me, comp, size, deadline, nil) end)
    {sent, shown} = collect_video(cam, watcher, guest, offset_us, %{}, %{})
    Home.Render.stop(video)

    lat =
      for {n, t} <- shown, s = sent[n], s != nil, do: (t - s) / 1_000

    %{latencies: lat, sent: map_size(sent), shown: map_size(shown)}
  end

  defp cam_size({node, id}) do
    [info] = Home.Registry.list(node: node) |> Enum.filter(&(&1.ref == {node, id}))
    {info.cap.meta.w, info.cap.meta.h}
  end

  defp collect_video(cam, watcher, guest, offset, sent, shown) do
    receive do
      {:synth_frame, ^cam, n, t} ->
        collect_video(
          cam,
          watcher,
          guest,
          offset,
          Map.put(sent, n, host_time(cam, t, guest, offset)),
          shown
        )

      {:shown, ^watcher, n, t} ->
        collect_video(cam, watcher, guest, offset, sent, Map.put_new(shown, n, t))

      {:watch_done, ^watcher} ->
        {sent, shown}
    end
  end

  # Poll the display's latest headless frame for the synthetic camera's frame number.
  defp watch(to, comp, size, deadline, last) do
    if System.monotonic_time(:millisecond) > deadline do
      send(to, {:watch_done, self()})
    else
      last =
        with %VideoInterop.Frame{} = frame <- Compositor.frame(comp),
             {:ok, n} when n != last <- Home.Media.SynthVideo.decode(picture(frame), size) do
          send(to, {:shown, self(), n, :os.system_time(:microsecond)})
          n
        else
          _ -> last
        end

      Process.sleep(2)
      watch(to, comp, size, deadline, last)
    end
  end

  defp picture(%VideoInterop.Frame{storage: %{data: data, planes: [plane]}} = frame) do
    offset = plane.offset
    <<_::binary-size(^offset), data::binary>> = data
    {data, plane.stride, 4, {frame.coded_width, frame.coded_height}}
  end

  ## Scene forwarding: app here -> headless display on the guest

  @doc "Show DemoMedia.App on `disp`; returns the render session."
  def show_app(disp) do
    {:ok, session} = Home.Render.show({DemoMedia.App, test: self()}, on: disp)
    session
  end

  def button_id(session) do
    %{children: [%{key: :inc, id: id}]} = :sys.get_state(session).tree
    Emerge.Engine.NodeId.encode(id)
  end

  @doc "Press the button on the display, as its renderer would report it. Returns host time."
  def press({node, _} = disp, button) do
    t = :os.system_time(:microsecond)
    :ok = :erpc.call(node, Compositor, :input, [compositor(disp), {button, :press}])
    t
  end

  @doc "RGBA at `{x, y}` of the display's latest headless frame (fetched over distribution)."
  def pixel({node, _} = disp, {x, y}) do
    case :erpc.call(node, Compositor, :frame, [compositor(disp)]) do
      %{storage: %{data: data, planes: [%{offset: offset, stride: stride} | _]}} ->
        at = offset + y * stride + x * 4
        <<_::binary-size(^at), r, g, b, a, _::binary>> = data
        {r, g, b, a}

      nil ->
        nil
    end
  end

  def await_pixel(disp, point, fun, ms) do
    Demo.eventually("pixel #{inspect(point)} on #{fmt(disp)}", ms, fn ->
      rgba = pixel(disp, point)
      rgba != nil and fun.(rgba) and :os.system_time(:microsecond)
    end)
  end

  def red?({r, g, b, _}), do: r > 200 and g < 60 and b < 60
  def blue?({r, g, b, _}), do: b > 200 and r < 60 and g < 60
  def green?({r, g, b, _}), do: g > 200 and r < 60 and b < 60

  ## Helpers

  def compositor({node, _} = cap) do
    {:ok, pid} = Home.Registry.whereis(cap)
    %{astate: %{compositor: comp}} = :erpc.call(node, :sys, :get_state, [pid])
    comp
  end

  defp host_time({node, _}, t, guest, offset) when node == guest, do: t - offset
  defp host_time(_cap, t, _guest, _offset), do: t

  def stats([]), do: "none"

  def stats(values) do
    s = Enum.sort(values)
    pct = fn p -> Enum.at(s, min(length(s) - 1, round(p * (length(s) - 1)))) end
    "n=#{length(s)} median #{r(pct.(0.5))} ms, p95 #{r(pct.(0.95))} ms, max #{r(List.last(s))} ms"
  end

  def p95(values) do
    s = Enum.sort(values)
    Enum.at(s, min(length(s) - 1, round(0.95 * (length(s) - 1))))
  end

  defp r(v), do: Float.round(v * 1.0, 1)

  def fmt({node, id}), do: "#{node}/#{id}"

  def flush do
    receive do
      {tag, _, _} when tag in [:synth_click, :home_hw] -> flush()
      {tag, _, _, _} when tag in [:synth_frame, :capture_onset] -> flush()
      {tag, _} when tag in [:capture_started] -> flush()
      {:capture_stats, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
