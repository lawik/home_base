defmodule Home.Media.Keyframes do
  @moduledoc """
  Pass-through filter right after a video encoder that turns a `:keyframe_request`
  parent notification into a `Membrane.KeyframeRequestEvent` to the encoder (which makes
  its next frame a keyframe).

  Requests within `min_interval` ms of the last one are dropped: the keyframe it caused
  is already on its way to everyone, and a receiver still missing one asks again.
  """

  use Membrane.Filter

  def_input_pad :input, accepted_format: _any
  def_output_pad :output, accepted_format: _any

  def_options min_interval: [
                spec: non_neg_integer(),
                default: 100,
                description: "ms between forced keyframes."
              ]

  @impl true
  def handle_init(_ctx, opts), do: {[], %{opts: opts, last: nil, forced: 0}}

  @impl true
  def handle_buffer(:input, buffer, _ctx, state), do: {[buffer: {:output, buffer}], state}

  @impl true
  def handle_parent_notification(:keyframe_request, _ctx, state) do
    now = System.monotonic_time(:millisecond)

    if state.last == nil or now - state.last >= state.opts.min_interval do
      state = %{state | last: now, forced: state.forced + 1}

      {[
         event: {:input, %Membrane.KeyframeRequestEvent{}},
         notify_parent: {:forced, state.forced}
       ], state}
    else
      {[], state}
    end
  end
end
