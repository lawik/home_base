defmodule Home.Test.DeclaredCamera do
  @moduledoc false
  # A synthetic camera (Home.Adapters.Video.SynthCamera) that says what it encodes:
  # `meta.video`, a list of Home.Media.Video.Format fields.
  @behaviour Home.Adapter

  alias Home.Adapters.Video.SynthCamera

  @impl true
  defdelegate init(cap), to: SynthCamera

  @impl true
  defdelegate start(state), to: SynthCamera

  @impl true
  defdelegate stop(state), to: SynthCamera

  @impl true
  defdelegate endpoint(state), to: SynthCamera

  @impl true
  def video(%{cap: %{meta: meta}}), do: meta.video
end
