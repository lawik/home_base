defmodule Home.Test.Counter do
  @moduledoc false
  use Solve.Controller, events: [:increment]

  @impl Solve.Controller
  def init(_params, _deps), do: %{count: 0}

  def increment(_payload, state), do: %{state | count: state.count + 1}
end

defmodule Home.Test.CounterApp do
  @moduledoc false
  use Solve

  @impl Solve
  def controllers, do: [controller!(name: :counter, module: Home.Test.Counter)]
end

defmodule Home.Test.CounterViewport do
  @moduledoc false
  # A Solve counter rendered with Emerge: red background for even counts, blue for odd.
  # The top-left 40x40 is a button that increments; below it is an image and Lobster
  # text, both from emerge's priv/ (they exist on the app's node only as far as the
  # display node is concerned: they go over the asset manifest step).
  use Emerge
  use Solve.Lookup

  @impl Viewport
  def mount(opts) do
    config = %Emerge.Config{
      runtime: Keyword.get(opts, :runtime, []),
      input: [events: Keyword.get(opts, :input_events, [])],
      assets: [
        otp_app: :emerge,
        fonts: [[family: "lobster", source: "test_assets/Lobster-Regular.ttf"]]
      ]
    }

    {:ok, %{app: Keyword.fetch!(opts, :app), test: opts[:test]}, config}
  end

  @impl Viewport
  def render(%{app: app}) do
    counter = solve(app, :counter)
    count = if counter, do: counter.count, else: 0
    bg = if rem(count, 2) == 0, do: color_rgb(255, 0, 0), else: color_rgb(0, 0, 255)

    column([width(fill()), height(fill()), Background.color(bg)], [
      Input.button(
        [
          width(px(40)),
          height(px(40)),
          key(:inc),
          Background.color(color_rgb(0, 255, 0)),
          Event.on_press(Solve.Lookup.event(counter, :increment))
        ],
        none()
      ),
      image([width(px(60)), height(px(20)), key(:img)], "sample_assets/static.jpg"),
      el([key(:label), Font.family("lobster"), Font.size(16)], text("count #{count}"))
    ])
  end

  @impl Viewport
  def handle_input(event, state) do
    if state.test, do: send(state.test, {:app_input, node(), event})
    {:noreply, state}
  end

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state), do: {:ok, Viewport.rerender(state)}
end

defmodule Home.Test.Render do
  @moduledoc false
  # Helpers that run on peers.

  @doc "Start the counter app and show it on `target`; return `{session, app}`."
  def show(target, opts \\ []) do
    {:ok, app} = GenServer.start(Home.Test.CounterApp, [])
    viewport_opts = Keyword.merge([app: app], opts)
    {:ok, session} = Home.Render.show({Home.Test.CounterViewport, viewport_opts}, on: target)
    {session, app}
  end

  @doc "Start the counter app rendered to pixels (§6.2) on `target`; return `{video, app}`."
  def show_pixels(target, opts \\ []) do
    {:ok, app} = GenServer.start(Home.Test.CounterApp, [])
    viewport_opts = Keyword.merge([app: app], opts)

    {:ok, video} =
      Home.Render.show_pixels({Home.Test.CounterViewport, viewport_opts}, on: target)

    {video, app}
  end

  def count(app), do: Solve.subscribe(app, :counter).count

  @doc "The element id (as emerge sends it in events) of the element keyed `key` in the session's tree."
  def element_id(session, key) do
    tree = :sys.get_state(session).tree
    %{id: id} = find(tree, key)
    Emerge.Engine.NodeId.encode(id)
  end

  defp find(%{key: key} = el, key), do: el

  defp find(el, key) do
    Enum.find_value(el.children ++ Enum.map(el.nearby, &elem(&1, 1)), &find(&1, key))
  end

  @doc "The display's compositor."
  def compositor(cap_id) do
    {:ok, pid} = Home.Registry.whereis({node(), cap_id})
    %{astate: %{compositor: comp}} = :sys.get_state(pid)
    comp
  end

  @doc "RGBA of the pixel at {x, y} in the display's latest headless frame, or nil."
  def pixel(cap_id, {x, y}) do
    case Home.Render.Compositor.frame(compositor(cap_id)) do
      nil ->
        nil

      %{storage: %{data: data, planes: [%{offset: offset, stride: stride} | _]}} ->
        at = offset + y * stride + x * 4
        <<_::binary-size(^at), r, g, b, a, _::binary>> = data
        {r, g, b, a}
    end
  end

  def shown(cap_id), do: Home.Render.Compositor.shown(compositor(cap_id))

  @doc "Press and release the left button at `{x, y}` on the display's renderer (hit-tested there)."
  def tap(cap_id, {x, y}) do
    comp = compositor(cap_id)
    :ok = Home.Render.Compositor.inject(comp, {:cursor_button, {:left, :press, [], {x, y}}})
    :ok = Home.Render.Compositor.inject(comp, {:cursor_button, {:left, :release, [], {x, y}}})
  end

  @doc "Whether the loaded emerge NIF has `EmergeSkia.inject_input/2` (a source build)."
  def inject_supported? do
    EmergeSkia.Native.renderer_inject_input(make_ref(), {:focused, true})
    true
  catch
    :error, :nif_not_loaded -> false
    :error, _ -> true
  end
end

defmodule Home.Test.FormViewport do
  @moduledoc false
  # A text input on top (y 0..30) and a scroll list below it (y 30..90) of 30 px stripes,
  # red, blue, red, ... Text changes go to `test` as {:changed, text}.
  use Emerge

  @impl Viewport
  def mount(opts) do
    config = %Emerge.Config{runtime: Keyword.get(opts, :runtime, []), assets: [otp_app: :emerge]}
    {:ok, %{test: opts[:test], text: ""}, config}
  end

  @impl Viewport
  def render(%{text: text}) do
    column([width(fill()), height(fill()), Background.color(color_rgb(0, 0, 0))], [
      Input.text(
        [key(:field), width(px(100)), height(px(30)), Event.on_change(:changed)],
        text
      ),
      column(
        [key(:list), width(fill()), height(px(60)), scrollbar_y()],
        for i <- 0..9 do
          color = if rem(i, 2) == 0, do: color_rgb(255, 0, 0), else: color_rgb(0, 0, 255)
          el([key(i), width(fill()), height(px(30)), Background.color(color)], none())
        end
      )
    ])
  end

  @impl Viewport
  def handle_info({:changed, text}, state) do
    if state.test, do: send(state.test, {:changed, text})
    {:noreply, Viewport.rerender(%{state | text: text})}
  end
end

defmodule Home.Test.OverlayViewport do
  @moduledoc false
  # Transparent, with a 20x20 button at the top right (x 180..200, y 0..20): green,
  # yellow once pressed. Presses go to `test` as {:overlay_pressed, n}.
  use Emerge

  @impl Viewport
  def mount(opts) do
    config = %Emerge.Config{runtime: Keyword.get(opts, :runtime, []), assets: [otp_app: :emerge]}
    {:ok, %{test: opts[:test], presses: 0}, config}
  end

  @impl Viewport
  def render(%{presses: presses}) do
    color = if presses == 0, do: color_rgb(0, 255, 0), else: color_rgb(255, 255, 0)

    el(
      [width(fill()), height(fill())],
      Input.button(
        [
          key(:ov),
          align_right(),
          align_top(),
          width(px(20)),
          height(px(20)),
          Background.color(color),
          Event.on_press(:pressed)
        ],
        none()
      )
    )
  end

  @impl Viewport
  def handle_info(:pressed, state) do
    presses = state.presses + 1
    if state.test, do: send(state.test, {:overlay_pressed, presses})
    {:noreply, Viewport.rerender(%{state | presses: presses})}
  end
end
