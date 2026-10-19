defmodule Home.Adapters.Video.SynthCamera do
  @moduledoc """
  `:video_in` adapter for a synthetic camera (`Home.Media.SynthVideo`): real-time paced
  I420 test pattern with the frame number drawn in. For tests and for checking a video
  path end to end without a camera.

  Capability meta: `:w`, `:h`, `:fps`, and `:notify` (a pid that gets
  `{:synth_frame, cap, n, wall_us}` per frame and `{:home_hw, cap_id, :on | :off}` when
  the "hardware" turns on or off).
  """

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
  def endpoint(%{cap: %{meta: meta} = cap}) do
    %Home.Media.SynthVideo{
      width: Map.get(meta, :w, 320),
      height: Map.get(meta, :h, 240),
      fps: Map.get(meta, :fps, 30),
      notify: Map.get(meta, :notify),
      cap: {node(), cap.id}
    }
  end

  defp notify(%{cap: %{id: id, meta: %{notify: pid}}}, what) when is_pid(pid),
    do: send(pid, {:home_hw, id, what})

  defp notify(_, _), do: :ok
end
