defmodule Home.Adapters.Light do
  @moduledoc """
  Adapter for a `:light` capability (see `Home.Light`). Takes the driver as an option:

      %{id: "led0", kind: :light,
        adapter: {Home.Adapters.Light, driver: {MyFirmware.Strip, MyFirmware.Strip}},
        meta: %{addressable: true, color_modes: [:rgb]}}

  The driver module implements `Home.Light.Driver`; the second element is passed back to
  it as the `ref`. The lease endpoint is that `{driver, ref}` pair. Turning the hardware
  "off" for an `:on_request` light means `driver.off/1`; "on" needs nothing, the light
  shows what it is told.
  """
  @behaviour Home.Adapter

  @impl true
  def init(%Home.Capability{meta: %{driver: {driver, ref}}} = cap) when is_atom(driver),
    do: {:ok, %{cap: cap, driver: driver, ref: ref}}

  def init(%Home.Capability{id: id}), do: {:error, {:no_driver, id}}

  @impl true
  def start(state), do: {:ok, state}

  @impl true
  def stop(%{driver: driver, ref: ref} = state) do
    driver.off(ref)
    {:ok, state}
  end

  @impl true
  def endpoint(%{driver: driver, ref: ref}), do: {driver, ref}
end
