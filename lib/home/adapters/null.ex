defmodule Home.Adapters.Null do
  @moduledoc "Adapter for capabilities that only announce themselves (zigbee, thread for now)."
  @behaviour Home.Adapter

  @impl true
  def init(cap), do: {:ok, %{cap: cap, on?: false}}
  @impl true
  def start(state), do: {:ok, %{state | on?: true}}
  @impl true
  def stop(state), do: {:ok, %{state | on?: false}}
  @impl true
  def endpoint(state), do: state.cap.meta
end
