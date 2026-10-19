defmodule Home.Adapters.Input do
  @moduledoc """
  `:input` capability for a display's input devices (pointer, touch, keyboard). Its
  own lease, separate from the display's: `:display` leases are shared and layered,
  `:input` is exclusive, and input goes to whoever holds it.

      %{id: "disp0", kind: :display, adapter: {Home.Adapters.Display, input: "input0"}},
      %{id: "input0", kind: :input, adapter: Home.Adapters.Input}

  The display adapter registers its compositor as the device behind `"input0"` (its
  renderer's backend reads the devices: evdev on DRM, the compositor on Wayland); the
  lease endpoint is that compositor. A lease holder routes the input with
  `Home.Render.Compositor.route_input/3`; `Home.Render.show/2` and the pixel/video
  sessions do it for their app (see `Home.Render.InputLease`).
  """
  @behaviour Home.Adapter

  @impl true
  def init(cap), do: {:ok, %{cap: cap}}

  @impl true
  def start(state), do: {:ok, state}

  @impl true
  def stop(state), do: {:ok, state}

  @impl true
  def endpoint(state), do: device(state.cap.id)

  @doc "The compositor registered as the device behind input capability `id` here, or nil."
  def device(id) do
    case :pg.get_local_members(:home, {:home_input_device, id}) do
      [comp | _] -> comp
      [] -> nil
    end
  end

  @doc false
  def register(id, comp), do: :pg.join(:home, {:home_input_device, id}, comp)
end
