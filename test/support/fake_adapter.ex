defmodule Home.Test.FakeAdapter do
  @moduledoc false
  # Records hardware on/off by sending {:fake_hw, cap_id, :on | :off} to meta.notify, if set.
  @behaviour Home.Adapter

  @impl true
  def init(cap), do: {:ok, %{cap: cap, on?: false}}

  @impl true
  def start(state) do
    notify(state, :on)
    {:ok, %{state | on?: true}}
  end

  @impl true
  def stop(state) do
    notify(state, :off)
    {:ok, %{state | on?: false}}
  end

  @impl true
  def endpoint(state), do: {:fake, state.cap.id}

  defp notify(%{cap: %{id: id, meta: %{notify: pid}}}, what), do: send(pid, {:fake_hw, id, what})
  defp notify(_, _), do: :ok
end
