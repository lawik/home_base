defmodule Home.Indicator.Viewport do
  @moduledoc """
  Emerge viewport for `Home.Indicator`: a list of the capabilities in use, each with who
  holds it and why, and a "Revoke all" button that calls `Home.Lease.revoke_all/0` on
  the node the viewport runs on.

  It starts its own `Home.Indicator.App`, linked, so the app lives and dies with it.
  Options: `:node` (only that node's capabilities), `:runtime` (as `Home.Render`
  passes it), `:output` (an `Emerge.Config` output, to run it locally in a window).

      Home.Render.show({Home.Indicator.Viewport, node: node()}, on: {node(), "disp0"})
  """

  use Emerge
  use Solve.Lookup

  @capture [:audio_in, :video_in]

  @impl Viewport
  def mount(opts) do
    # Under Home.Render the session holds the display lease for us; don't list it.
    session = get_in(opts, [:runtime, :adapter_opts, :session])
    params = opts |> Keyword.take([:node]) |> Map.new() |> Map.put(:hide, session)
    {:ok, app} = Home.Indicator.App.start_link(params: params)

    config =
      %Emerge.Config{runtime: Keyword.get(opts, :runtime, [])}
      |> then(&if(output = opts[:output], do: %{&1 | output: output}, else: &1))

    {:ok, %{app: app}, config}
  end

  @impl Viewport
  def render(%{app: app}) do
    leases = solve(app, :leases)

    column(
      [
        width(fill()),
        height(fill()),
        padding(12),
        spacing(8),
        Background.color(color(:slate, 900)),
        Font.color(color(:slate, 100)),
        Font.size(14)
      ],
      [header(leases) | rows(leases)]
    )
  end

  defp header(leases) do
    title =
      case leases do
        nil -> "…"
        %{in_use: []} -> "Nothing in use"
        %{in_use: rows} -> "#{length(rows)} in use"
      end

    row([width(fill()), spacing(8), key(:header)], [
      el([width(fill()), center_y(), Font.size(16), key(:title)], text(title)),
      Input.button(
        [
          key(:revoke_all),
          padding_xy(10, 6),
          Border.rounded(6),
          Background.color(color(:red, 600)),
          Event.on_press(event(leases, :revoke_all))
        ],
        text("Revoke all")
      )
    ])
  end

  defp rows(nil), do: []

  defp rows(%{in_use: in_use}) do
    for cap <- in_use do
      row([width(fill()), spacing(8), key({:cap, cap.ref})], [
        el(
          [
            width(px(10)),
            height(px(10)),
            center_y(),
            Border.rounded(5),
            Background.color(dot(cap))
          ],
          none()
        ),
        el([width(fill())], text(describe(cap)))
      ])
    end
  end

  @doc false
  # "mic0 on kitchen (Kitchen): held by laptop, intercom"
  def describe(cap) do
    where = if cap.area, do: "#{cap.device} (#{cap.area})", else: cap.device
    state = if cap.hardware == :on, do: "on", else: "off"

    holders =
      case cap.holders do
        [] ->
          "not held"

        holders ->
          "held by " <>
            Enum.map_join(holders, ", ", fn h ->
              if h.purpose, do: "#{h.name}, #{h.purpose}", else: h.name
            end)
      end

    "#{cap.id} on #{where}, #{state}: #{holders}"
  end

  defp dot(%{kind: kind, hardware: :on}) when kind in @capture, do: color(:red, 500)
  defp dot(%{hardware: :on}), do: color(:amber, 400)
  defp dot(_), do: color(:slate, 500)

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state), do: {:ok, Viewport.rerender(state)}
end
