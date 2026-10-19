defmodule Home.Test.Chain do
  @moduledoc false
  # A pipeline that links the given children in order. `start/1` runs it unlinked, so it
  # can be started on a peer over rpc.
  use Membrane.Pipeline

  def start(children) do
    {:ok, _sup, pipeline} = Membrane.Pipeline.start(__MODULE__, children)
    {:ok, pipeline}
  end

  @impl true
  def handle_init(_ctx, [first | rest]) do
    spec =
      rest
      |> Enum.with_index(1)
      |> Enum.reduce(child({:c, 0}, first), fn {c, i}, acc -> acc |> child({:c, i}, c) end)

    {[spec: spec], %{}}
  end
end
