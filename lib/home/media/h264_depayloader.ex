defmodule Home.Media.H264Depayloader do
  @moduledoc """
  RTP H.264 depayloader (RFC 6184: single NAL unit, STAP-A and FU-A packets) that puts
  out whole access units, each as soon as its last packet is in.

  The RTP marker bit is set on the last packet of an access unit (RFC 6184 §5.1).
  `Membrane.RTP.H264.Depayloader` emits NAL units and copies a STAP-A's marker onto every
  NAL unit in it, so a parser after it can't tell where an access unit ends before the
  next one starts, one frame interval later. Here the access unit ends on the marker,
  or when the RTP timestamp changes in case a marker went missing; the parser after
  this gets `alignment: :au` and passes each one straight on to the decoder.

  After a loss (a `Membrane.Event.Discontinuity` from the jitter buffer, or a broken
  fragmented NAL unit) the frames that follow can't be decoded correctly until the next
  keyframe: they are dropped (the picture freezes rather than smears) and the parent
  gets `:keyframe_request`, then again every `retry` ms while it waits. The same holds at
  the start, until the first keyframe.
  """

  use Membrane.Filter

  alias Membrane.{Buffer, H264, RTP}
  alias Membrane.Event.Discontinuity
  alias Membrane.RTP.H264.{FU, NAL, StapA}

  def_input_pad :input, accepted_format: %RTP{payload_format: format} when format in [nil, H264]
  def_output_pad :output, accepted_format: %H264{alignment: :au, stream_structure: :annexb}

  def_options retry: [
                spec: pos_integer(),
                default: 250,
                description: "ms between keyframe requests while waiting for one."
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       opts: opts,
       # NAL units of the access unit being assembled, last first.
       nalus: [],
       fu: nil,
       ts: nil,
       pts: nil,
       dts: nil,
       broken?: false,
       keyframe?: false,
       waiting?: true,
       requested_at: nil,
       dropped: 0
     }}
  end

  @impl true
  def handle_stream_format(:input, _format, _ctx, state),
    do: {[stream_format: {:output, %H264{alignment: :au, stream_structure: :annexb}}], state}

  @impl true
  def handle_buffer(
        :input,
        %Buffer{payload: payload, metadata: %{rtp: rtp}} = buffer,
        _ctx,
        state
      ) do
    # A new timestamp starts a new access unit, even if the last one's marker was lost.
    {actions, state} =
      if state.ts != nil and rtp.timestamp != state.ts and (state.nalus != [] or state.fu),
        do: flush(state),
        else: {[], state}

    state = %{state | ts: rtp.timestamp, pts: buffer.pts, dts: buffer.dts}
    state = depayload(payload, state)

    if rtp.marker do
      {more, state} = flush(state)
      {actions ++ more, state}
    else
      {actions, state}
    end
  end

  @impl true
  def handle_event(:input, %Discontinuity{}, _ctx, state) do
    state = %{reset(state) | waiting?: true}
    request(state, true)
  end

  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  defp depayload(payload, state) do
    with {:ok, {header, data}} <- NAL.Header.parse_unit_header(payload) do
      case NAL.Header.decode_type(header) do
        :single_nalu ->
          add(state, payload)

        :stap_a ->
          case StapA.parse(data) do
            {:ok, nalus} -> Enum.reduce(nalus, state, &add(&2, &1))
            {:error, _} -> %{state | broken?: true}
          end

        :fu_a ->
          case FU.parse(data, state.fu || %FU{}) do
            {:ok, {nalu, type}} ->
              add(%{state | fu: nil}, NAL.Header.add_header(nalu, 0, header.nal_ref_idc, type))

            {:incomplete, fu} ->
              %{state | fu: fu}

            {:error, _} ->
              %{state | fu: nil, broken?: true}
          end

        _other ->
          %{state | broken?: true}
      end
    else
      _ -> %{state | broken?: true}
    end
  end

  defp add(state, nalu) do
    %{state | nalus: [nalu | state.nalus], keyframe?: state.keyframe? or idr?(nalu)}
  end

  # An access unit that lost a fragment, or a frame before a keyframe after a loss: drop.
  defp flush(%{broken?: true} = state),
    do: request(%{reset(state) | waiting?: true, dropped: state.dropped + 1}, false)

  defp flush(%{fu: %FU{}} = state),
    do: request(%{reset(state) | waiting?: true, dropped: state.dropped + 1}, false)

  defp flush(%{nalus: []} = state), do: {[], state}

  defp flush(%{waiting?: true, keyframe?: false} = state),
    do: request(%{reset(state) | dropped: state.dropped + 1}, false)

  defp flush(state) do
    payload = state.nalus |> Enum.reverse() |> Enum.map(&[<<0, 0, 0, 1>>, &1])
    buffer = %Buffer{payload: IO.iodata_to_binary(payload), pts: state.pts, dts: state.dts}
    {[buffer: {:output, buffer}], %{reset(state) | waiting?: false}}
  end

  defp reset(state), do: %{state | nalus: [], fu: nil, broken?: false, keyframe?: false}

  defp request(state, now?) do
    now = System.monotonic_time(:millisecond)

    if now? or state.requested_at == nil or now - state.requested_at >= state.opts.retry,
      do: {[notify_parent: :keyframe_request], %{state | requested_at: now}},
      else: {[], state}
  end

  # NAL unit type 5: a slice of an IDR picture.
  defp idr?(<<_::3, 5::5, _::binary>>), do: true
  defp idr?(_nalu), do: false
end
