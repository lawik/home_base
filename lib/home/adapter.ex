defmodule Home.Adapter do
  @moduledoc """
  Hardware adapter for one capability. `start/1` turns the hardware on, `stop/1` off.
  `endpoint/1` is whatever a consumer needs to use it: a Membrane child spec, a display
  surface, a read function.
  """

  @type state :: term()

  @callback init(Home.Capability.t()) :: {:ok, state} | {:error, term}
  @callback start(state) :: {:ok, state}
  @callback stop(state) :: {:ok, state}
  @callback endpoint(state) :: term
end
