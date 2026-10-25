defmodule Home.Light do
  @moduledoc """
  The `:light` capability: LEDs a node lends out, from one on/off indicator to an
  addressable strip.

  A light is vended with `Home.Adapters.Light` and a *driver*, the node-local module that
  owns the hardware (an SPI strip, a GPIO, a PWM channel). The driver implements
  `Home.Light.Driver`; the lease endpoint is the `{driver, ref}` pair, and the functions
  here call it on the owning node for the lease holder.

      %{
        id: "led0",
        kind: :light,
        adapter: {Home.Adapters.Light, driver: {MyFirmware.Strip, MyFirmware.Strip}},
        meta: %{addressable: true, color_modes: [:rgb]}
      }

  `meta` describes what the light can do so a consumer can pick one from
  `Home.Registry.list(kind: :light)` without leasing it first:

    * `addressable` - `true` for a strip whose pixels are set one by one (`set_frame/2`),
      `false` for a single light or a strip that only takes one colour.
    * `color_modes` - the richest first: `:rgb` (any colour), `:brightness` (one
      colour, dimmable), `:on_off`.
    * `leds` - how many pixels an addressable strip has, when fixed. A strip whose
      length is configured at runtime leaves it out; `info/1` tells the current count.

  Colours are `{r, g, b}` bytes and are what the light should emit: brightness is
  already applied. A light that cannot show a colour shows the nearest thing it can
  (a `:brightness` light its level, an `:on_off` light on for anything but black).

      {:ok, lease} = Home.Lease.acquire({node, "led0"}, purpose: "doorbell")
      :ok = Home.Light.set_color(lease, {255, 80, 0})
      :ok = Home.Light.set_frame(lease, <<255, 0, 0, 0, 255, 0, 0, 0, 255>>)
      :ok = Home.Light.off(lease)

  Lights take one lease at a time: two holders painting one strip would fight. Releasing
  the lease leaves the light as it was; the owner (its Home Assistant entity, say) is
  expected to repaint it.
  """

  alias Home.Lease

  @type rgb :: {byte(), byte(), byte()}
  @type color_mode :: :rgb | :brightness | :on_off

  @typedoc "What a driver reports about its light."
  @type info :: %{
          required(:addressable) => boolean(),
          required(:color_modes) => [color_mode()],
          optional(:leds) => pos_integer()
        }

  defmodule Driver do
    @moduledoc """
    The node-local module behind a `:light` capability. `ref` is whatever the manifest
    gave as the driver's second element, typically the registered name of its process.
    """

    @callback info(ref :: term()) :: Home.Light.info()
    @callback set_color(ref :: term(), Home.Light.rgb()) :: :ok | {:error, term()}
    @callback set_frame(ref :: term(), frame :: binary()) :: :ok | {:error, term()}
    @callback off(ref :: term()) :: :ok | {:error, term()}
  end

  @doc "What the leased light can do right now; see `t:info/0`."
  @spec info(Lease.t()) :: info() | {:error, term()}
  def info(%Lease{} = lease), do: call(lease, :info, [])

  @doc "Show one colour on the whole light."
  @spec set_color(Lease.t(), rgb()) :: :ok | {:error, term()}
  def set_color(%Lease{} = lease, {r, g, b} = rgb)
      when r in 0..255 and g in 0..255 and b in 0..255,
      do: call(lease, :set_color, [rgb])

  @doc """
  Paint an addressable strip pixel by pixel: `frame` is RGB bytes, three per pixel. A
  frame shorter than the strip leaves the rest dark; a longer one is cut. A light that
  is not addressable answers `{:error, :not_addressable}`.
  """
  @spec set_frame(Lease.t(), binary()) :: :ok | {:error, term()}
  def set_frame(%Lease{} = lease, frame) when is_binary(frame) and rem(byte_size(frame), 3) == 0,
    do: call(lease, :set_frame, [frame])

  @doc "Turn the light off."
  @spec off(Lease.t()) :: :ok | {:error, term()}
  def off(%Lease{} = lease), do: call(lease, :off, [])

  defp call(%Lease{endpoint: {driver, ref}, server: server}, fun, args) do
    :erpc.call(node(server), driver, fun, [ref | args], 5_000)
  catch
    :error, {:erpc, reason} -> {:error, {:erpc, reason}}
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp call(%Lease{endpoint: other}, _fun, _args), do: {:error, {:not_a_light, other}}
end
