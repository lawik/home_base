defmodule Home.Test.IndicatorHelpers do
  @moduledoc false
  # Lease indicator helpers that run on peers.

  @doc "Start the indicator's Solve app, not linked to the (short-lived) rpc caller."
  def start_app(params \\ %{}), do: GenServer.start(Home.Indicator.App, params: params)

  @doc "The `:leases` controller's exposed state."
  def leases(app), do: Solve.subscribe(app, :leases)

  @doc "Start a `Home.Indicator` keeper, not linked to the caller."
  def start_keeper(opts), do: GenServer.start(Home.Indicator, opts)

  @doc "How many pixels of the display's latest headless frame are `{r, g, b}`."
  def count_pixels(cap_id, {r, g, b}) do
    case Home.Render.Compositor.frame(Home.Test.Render.compositor(cap_id)) do
      nil -> 0
      %{storage: %{data: data}} -> for(<<^r, ^g, ^b, _a <- data>>, do: 1) |> length()
    end
  end

  @doc "Every text in the session's current tree, in tree order."
  def texts(session) do
    case :sys.get_state(session).tree do
      nil -> []
      tree -> collect(tree)
    end
  end

  defp collect(%{type: :text, attrs: %{content: content}}), do: [content]

  defp collect(el) do
    Enum.flat_map(el.children ++ Enum.map(el.nearby, &elem(&1, 1)), &collect/1)
  end
end
