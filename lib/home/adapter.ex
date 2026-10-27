defmodule Home.Adapter do
  @moduledoc """
  Hardware adapter for one capability. `start/1` turns the hardware on, `stop/1` off.
  `endpoint/1` is whatever a consumer needs to use it: a Membrane child spec, a display
  surface, a read function.

  A `:video_in` or `:display` adapter may say what video it encodes or decodes with
  `video/1` (`Home.Media.Video.Format`s, or maps of their fields). Without it a camera is
  taken to send raw frames for x264, and a display to decode with its node's decoders
  (see `Home.Media.Video`).
  """

  @type state :: term()

  @callback init(Home.Capability.t()) :: {:ok, state} | {:error, term}
  @callback start(state) :: {:ok, state}
  @callback stop(state) :: {:ok, state}
  @callback endpoint(state) :: term
  @callback video(state) :: [Home.Media.Video.Format.t() | map()]

  @optional_callbacks video: 1
end
