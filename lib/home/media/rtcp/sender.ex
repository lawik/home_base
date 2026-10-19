defmodule Home.Media.RTCP.Sender do
  @moduledoc """
  RTCP at the source of a session, between the RTP muxer and the fan-out (see
  `Home.Media.RTCP`).

  RTP from `:input` passes through to `:output`. Every `interval` a sender report (SR) for
  the stream goes out on `:output` too, so every sink gets it. Each sink's UDP endpoint
  links its incoming datagrams to a `Pad.ref(:feedback, id)`:

    * receiver reports become `{:receiver_report, id, report}` notifications to the parent
      (`report`: `fraction_lost` 0..1, `lost`, `highest_seq`, `jitter_ms`, `rtt_ms` or nil);
    * a PLI or FIR becomes `{:keyframe_request, id}`;
    * a generic NACK is answered by resending the packets still in the `history` (the
      same packets, RFC 4585 §3.1 without an RTX stream: a receiver that already has one
      drops the copy).

  With each SR the parent gets `{:sender_stats, stats}` (packets and octets sent, NACKed
  and retransmitted packets, keyframe requests).
  """

  use Membrane.Filter, flow_control_hints?: false

  require Membrane.Pad

  alias ExRTCP.Packet.{PayloadFeedback, ReceiverReport, ReceptionReport, SenderReport}
  alias ExRTCP.Packet.TransportFeedback.NACK
  alias Home.Media.RTCP
  alias Membrane.{Buffer, Pad, RemoteStream, Time}

  def_input_pad :input, accepted_format: %RemoteStream{type: :packetized}

  def_input_pad :feedback,
    availability: :on_request,
    flow_control: :push,
    accepted_format: _any

  def_output_pad :output, accepted_format: %RemoteStream{type: :packetized}

  def_options clock_rate: [spec: pos_integer(), description: "RTP clock rate of the stream."],
              interval: [spec: pos_integer(), default: 1_000, description: "ms between SRs."],
              history: [
                spec: non_neg_integer(),
                default: 1_024,
                description: "Packets kept for retransmission on NACK."
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       opts: opts,
       ssrc: nil,
       packets: 0,
       octets: 0,
       last_ts: nil,
       last_wall: nil,
       history: %{},
       order: :queue.new(),
       retransmitted: 0,
       nacked: 0,
       keyframe_requests: 0
     }}
  end

  @impl true
  def handle_playing(_ctx, state),
    do: {[start_timer: {:report, Time.milliseconds(state.opts.interval)}], state}

  @impl true
  def handle_stream_format(:input, format, _ctx, state),
    do: {[stream_format: {:output, format}], state}

  def handle_stream_format(_feedback, _format, _ctx, state), do: {[], state}

  @impl true
  def handle_buffer(:input, %Buffer{payload: payload} = buffer, _ctx, state) do
    case payload do
      <<2::2, _p::1, _x::1, cc::4, _m::1, _pt::7, seq::16, ts::32, ssrc::32, _::binary>> ->
        first? = state.ssrc == nil

        state = %{
          state
          | ssrc: ssrc,
            packets: state.packets + 1,
            octets: state.octets + max(0, byte_size(payload) - 12 - 4 * cc),
            last_ts: ts,
            last_wall: System.monotonic_time(:microsecond)
        }

        # The first SR right away, so receivers can report a round trip early.
        sr = if first?, do: sender_report(state), else: []
        {[buffer: {:output, buffer}] ++ sr, remember(state, seq, payload)}

      _ ->
        {[buffer: {:output, buffer}], state}
    end
  end

  def handle_buffer(Pad.ref(:feedback, id), %Buffer{payload: payload}, _ctx, state) do
    case ExRTCP.CompoundPacket.decode(payload) do
      {:ok, packets} -> Enum.flat_map_reduce(packets, state, &feedback(&1, id, &2))
      {:error, _} -> {[], state}
    end
  end

  @impl true
  # A sink's endpoint going away ends only its feedback.
  def handle_end_of_stream(:input, _ctx, state), do: {[end_of_stream: :output], state}
  def handle_end_of_stream(_feedback, _ctx, state), do: {[], state}

  @impl true
  def handle_tick(:report, _ctx, %{ssrc: nil} = state), do: {[], state}

  def handle_tick(:report, _ctx, state), do: {sender_report(state), state}

  # An SR now, and the stats so far.
  defp sender_report(state) do
    elapsed = System.monotonic_time(:microsecond) - state.last_wall
    rtp_ts = state.last_ts + div(elapsed * state.opts.clock_rate, 1_000_000)

    sr = %SenderReport{
      ssrc: state.ssrc,
      ntp_timestamp: RTCP.ntp_now(),
      rtp_timestamp: Bitwise.band(rtp_ts, 0xFFFFFFFF),
      packet_count: Bitwise.band(state.packets, 0xFFFFFFFF),
      octet_count: Bitwise.band(state.octets, 0xFFFFFFFF)
    }

    stats = %{
      packets: state.packets,
      octets: state.octets,
      nacked: state.nacked,
      retransmitted: state.retransmitted,
      keyframe_requests: state.keyframe_requests
    }

    payload = ExRTCP.CompoundPacket.encode([sr])
    [buffer: {:output, %Buffer{payload: payload}}, notify_parent: {:sender_stats, stats}]
  end

  defp feedback(%ReceiverReport{reports: reports}, id, state) do
    actions =
      for %ReceptionReport{ssrc: ssrc} = r <- reports, ssrc == state.ssrc do
        {:notify_parent, {:receiver_report, id, report(r, state.opts.clock_rate)}}
      end

    {actions, state}
  end

  defp feedback(%module{media_ssrc: ssrc}, id, %{ssrc: ssrc} = state)
       when module in [PayloadFeedback.PLI, PayloadFeedback.FIR] do
    {[notify_parent: {:keyframe_request, id}],
     %{state | keyframe_requests: state.keyframe_requests + 1}}
  end

  defp feedback(%NACK{media_ssrc: ssrc} = nack, _id, %{ssrc: ssrc} = state) do
    seqs = NACK.to_sequence_numbers(nack)
    resend = for seq <- seqs, payload = state.history[seq], do: %Buffer{payload: payload}

    state = %{
      state
      | nacked: state.nacked + length(seqs),
        retransmitted: state.retransmitted + length(resend)
    }

    {[buffer: {:output, resend}], state}
  end

  # FIR has no media_ssrc of its own: its entries name the SSRC.
  defp feedback(%PayloadFeedback.FIR{entries: entries}, id, state) do
    if Enum.any?(entries, &(&1.ssrc == state.ssrc)) do
      {[notify_parent: {:keyframe_request, id}],
       %{state | keyframe_requests: state.keyframe_requests + 1}}
    else
      {[], state}
    end
  end

  defp feedback(_packet, _id, state), do: {[], state}

  defp report(%ReceptionReport{} = r, clock_rate) do
    rtt =
      if r.last_sr == 0 do
        nil
      else
        now = RTCP.middle32(RTCP.ntp_now())
        units = Bitwise.band(now - r.last_sr - r.delay, 0xFFFFFFFF)
        # A report from before a clock step, or garbage: no RTT.
        if units < 65_536 * 10, do: Float.round(RTCP.units_to_ms(units), 2)
      end

    %{
      fraction_lost: Float.round(r.fraction_lost / 256, 3),
      lost: r.total_lost,
      highest_seq: r.last_sequence_number,
      jitter_ms: Float.round(r.jitter * 1_000 / clock_rate, 2),
      rtt_ms: rtt
    }
  end

  defp remember(%{opts: %{history: 0}} = state, _seq, _payload), do: state

  defp remember(state, seq, payload) do
    order = :queue.in(seq, state.order)
    history = Map.put(state.history, seq, payload)

    if map_size(history) > state.opts.history do
      {{:value, old}, order} = :queue.out(order)
      %{state | history: Map.delete(history, old), order: order}
    else
      %{state | history: history, order: order}
    end
  end
end
