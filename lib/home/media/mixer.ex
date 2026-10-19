defmodule Home.Media.Mixer do
  @moduledoc """
  The output side of a mixed speaker (§5.3): `Membrane.LiveAudioMixer` → the speaker's own
  endpoint, in one long-running pipeline owned by the capability (see
  `Home.Adapters.Audio.Mixer`).

  Each session that plays on the speaker ends its sink pipeline in a `Home.Media.Mixer.Input`
  element, which forwards decoded audio here; the mixer gets one input pad per such element
  and drops it when the element goes away.

  The first input's format is the mix's; an input in another s16le format (rate or
  channels) is converted on the way in (`Home.Media.Mixer.Convert`) rather than
  taking the mix down.

  Options: `:output` (the endpoint child), `:slack` (extra ms of headroom per input, default
  0: the session's jitter buffer already starts each input with a queue).
  """

  use Membrane.Pipeline

  require Logger

  alias Membrane.{RawAudio, Time}

  @doc false
  def start_link(opts), do: Membrane.Pipeline.start_link(__MODULE__, Map.new(opts))

  @doc "Start without a link to the caller (who should monitor the pipeline)."
  def start(opts), do: Membrane.Pipeline.start(__MODULE__, Map.new(opts))

  @doc "Number of sessions currently feeding the mixer."
  def inputs(mixer), do: Membrane.Pipeline.call(mixer, :inputs)

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      child(:mixer, %Membrane.LiveAudioMixer{latency: 0})
      |> child(:output, opts.output)

    {[spec: spec], %{slack: Map.get(opts, :slack, 0), inputs: %{}, format: nil}}
  end

  @impl true
  def handle_info({:mixer_input, from, {:format, format}}, _ctx, state) do
    cond do
      Map.has_key?(state.inputs, from) ->
        {[], state}

      not convertible?(format, state.format) ->
        Logger.warning("mixer: can't mix #{inspect(format)} into #{inspect(state.format)}")
        {[], state}

      true ->
        add_input(from, format, state)
    end
  end

  def handle_info({:mixer_input, from, {:buffer, buffer}}, _ctx, state) do
    case state.inputs do
      %{^from => :playing} ->
        {[notify_child: {{:input, from}, {:buffer, buffer}}], state}

      %{^from => {:starting, pending}} ->
        {[], put_in(state.inputs[from], {:starting, [buffer | pending]})}

      _ ->
        {[], state}
    end
  end

  def handle_info({:DOWN, _, :process, from, _}, _ctx, state) do
    case Map.pop(state.inputs, from) do
      {nil, _} -> {[], state}
      {_, inputs} -> {[notify_child: {{:input, from}, :end_of_stream}], %{state | inputs: inputs}}
    end
  end

  def handle_info(_msg, _ctx, state), do: {[], state}

  defp add_input(from, format, state) do
    Process.monitor(from)
    mix = state.format || format

    spec =
      child({:input, from}, %Home.Media.Mixer.Source{
        format: format,
        output_format: mix,
        delay: Time.milliseconds(state.slack)
      })
      |> via_in(:input, options: [offset: :live])
      |> get_child(:mixer)

    {[spec: spec], %{put_in(state.inputs[from], {:starting, []}) | format: mix}}
  end

  defp convertible?(_format, nil), do: true
  defp convertible?(format, format), do: true

  defp convertible?(%RawAudio{sample_format: :s16le}, %RawAudio{sample_format: :s16le}),
    do: true

  defp convertible?(_format, _mix), do: false

  @impl true
  def handle_call(:inputs, _ctx, state), do: {[reply: map_size(state.inputs)], state}

  @impl true
  def handle_child_playing({:input, from}, _ctx, state) do
    case state.inputs do
      %{^from => {:starting, pending}} ->
        actions =
          for b <- Enum.reverse(pending), do: {:notify_child, {{:input, from}, {:buffer, b}}}

        {actions, put_in(state.inputs[from], :playing)}

      _ ->
        {[], state}
    end
  end

  def handle_child_playing(_child, _ctx, state), do: {[], state}

  @impl true
  def handle_child_notification(:ended, {:input, _} = child, _ctx, state),
    do: {[remove_children: child], state}

  def handle_child_notification(_msg, _child, _ctx, state), do: {[], state}
end
