defmodule Home.Capability do
  @moduledoc """
  One piece of hardware a node vends: a mic, a speaker, a display, a radio, a sensor.

  `availability`:

    * `:always` - vended as soon as the node is up; hardware is started at boot.
    * `:on_request` - hardware is off until a lease starts it, and off again on the last release.
    * `:off` - present but disabled by the owner; never vended.
  """

  @kinds [
    :audio_in,
    :audio_out,
    :video_in,
    :display,
    :input,
    :zigbee,
    :thread,
    :sensor,
    :presence
  ]

  @enforce_keys [:id, :kind]
  defstruct [:id, :kind, availability: :always, adapter: nil, max_age: nil, meta: %{}]

  @type id :: String.t()
  @type kind ::
          :audio_in
          | :audio_out
          | :video_in
          | :display
          | :input
          | :zigbee
          | :thread
          | :sensor
          | :presence
  @type ref :: {node(), id()}
  @type t :: %__MODULE__{
          id: id(),
          kind: kind(),
          availability: :always | :on_request | :off,
          adapter: module() | {module(), keyword()} | nil,
          max_age: pos_integer() | nil,
          meta: map()
        }

  def kinds, do: @kinds

  @doc "Lease max age in ms: the capability's own, else 10 min for capture kinds, 60 min otherwise."
  def max_age(%__MODULE__{max_age: ms}) when is_integer(ms), do: ms
  def max_age(%__MODULE__{kind: kind}) when kind in [:audio_in, :video_in], do: :timer.minutes(10)
  def max_age(%__MODULE__{}), do: :timer.minutes(60)

  @doc "Kinds where several leases can be held at once (the adapter mixes or layers them)."
  def shareable?(%__MODULE__{kind: kind}), do: kind in [:audio_out, :display]
end
