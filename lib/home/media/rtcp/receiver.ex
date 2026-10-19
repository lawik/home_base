defmodule Home.Media.RTCP.Receiver do
  @moduledoc """
  RTCP at a sink of a session, between the UDP endpoint and the RTP demuxer (see
  `Home.Media.RTCP`).

  RTP for stream `ssrc` passes through to `:output` and is counted the RFC 3550 way
  (extended highest sequence number, cumulative and interval loss, interarrival jitter).
  The source's sender reports are consumed. `:feedback` goes back into the UDP endpoint,
  which sends it to wherever the RTP comes from:

    * a receiver report (RR) every `interval`, with the delay since the last SR so the
      source can work out the round trip;
    * with `nack: true`, a generic NACK as soon as a sequence gap shows up, so the source
      can resend before the jitter buffer gives up on the packet;
    * a PLI when the parent notifies `:keyframe_request` (at most one per 100 ms).

  Each interval the parent gets `{:receiver_stats, stats}`.
  """

  use Membrane.Filter, flow_control_hints?: false

  import Bitwise

  alias ExRTCP.Packet.{PayloadFeedback, ReceiverReport, ReceptionReport, SenderReport}
  alias ExRTCP.Packet.TransportFeedback.NACK
  alias Home.Media.RTCP
  alias Membrane.{Buffer, RemoteStream, Time}

  @pli_every_ms 100
  @max_gap 256
  @nack_max 64

  def_input_pad :input, accepted_format: %RemoteStream{type: :packetized}
  def_output_pad :output, accepted_format: %RemoteStream{type: :packetized}

  def_output_pad :feedback,
    accepted_format: %RemoteStream{type: :packetized},
    flow_control: :push

  def_options ssrc: [spec: non_neg_integer(), description: "The stream's SSRC."],
              clock_rate: [spec: pos_integer(), description: "RTP clock rate of the stream."],
              interval: [spec: pos_integer(), default: 1_000, description: "ms between RRs."],
              nack: [spec: boolean(), default: true, description: "Send NACKs for gaps."]

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       opts: opts,
       own_ssrc: Enum.random(1..0xFFFFFFFF),
       base: nil,
       max: nil,
       received: 0,
       expected_prior: 0,
       received_prior: 0,
       fraction_lost: 0,
       jitter: 0.0,
       transit: nil,
       missing: %{},
       nacked: 0,
       recovered: 0,
       duplicates: 0,
       plis: 0,
       last_pli: nil,
       lsr: nil
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[
       stream_format: {:feedback, %RemoteStream{type: :packetized}},
       start_timer: {:report, Time.milliseconds(state.opts.interval)}
     ], state}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, state),
    do: {[stream_format: {:output, format}], state}

  @impl true
  def handle_buffer(:input, %Buffer{payload: payload} = buffer, _ctx, state) do
    ssrc = state.opts.ssrc

    cond do
      RTCP.rtcp?(payload) ->
        {[], sender_report(payload, state)}

      match?(<<_::64, ^ssrc::32, _::binary>>, payload) ->
        <<_::16, seq::16, ts::32, _::binary>> = payload
        rtp(seq, ts, buffer, state)

      true ->
        {[buffer: {:output, buffer}], state}
    end
  end

  @impl true
  def handle_parent_notification(:keyframe_request, _ctx, %{max: nil} = state), do: {[], state}

  def handle_parent_notification(:keyframe_request, _ctx, state) do
    now = System.monotonic_time(:millisecond)

    if state.last_pli == nil or now - state.last_pli >= @pli_every_ms do
      pli = %PayloadFeedback.PLI{sender_ssrc: state.own_ssrc, media_ssrc: state.opts.ssrc}
      {[feedback([pli])], %{state | plis: state.plis + 1, last_pli: now}}
    else
      {[], state}
    end
  end

  @impl true
  def handle_tick(:report, _ctx, %{max: nil} = state), do: {[], state}

  def handle_tick(:report, _ctx, state) do
    expected = state.max - state.base + 1
    lost = expected - state.received
    expected_interval = expected - state.expected_prior
    lost_interval = expected_interval - (state.received - state.received_prior)

    fraction =
      if expected_interval == 0 or lost_interval <= 0,
        do: 0,
        else: min(255, div(lost_interval <<< 8, expected_interval))

    {last_sr, delay} =
      case state.lsr do
        nil -> {0, 0}
        {lsr, at} -> {lsr, RTCP.ms_to_units(System.monotonic_time(:millisecond) - at)}
      end

    report = %ReceptionReport{
      ssrc: state.opts.ssrc,
      fraction_lost: fraction,
      total_lost: lost |> max(0) |> min(0x7FFFFF),
      last_sequence_number: state.max &&& 0xFFFFFFFF,
      jitter: trunc(state.jitter),
      last_sr: last_sr,
      delay: delay
    }

    # Gaps this far behind won't be filled any more.
    horizon = state.max - 2_048

    state = %{
      state
      | expected_prior: expected,
        received_prior: state.received,
        fraction_lost: fraction,
        missing: Map.reject(state.missing, fn {ext, _} -> ext < horizon end)
    }

    rr = %ReceiverReport{ssrc: state.own_ssrc, reports: [report]}
    {[feedback([rr]), notify_parent: {:receiver_stats, stats(state)}], state}
  end

  defp rtp(seq, ts, buffer, state) do
    now_us = System.monotonic_time(:microsecond)

    state =
      case state.max do
        nil ->
          %{state | base: seq, max: seq, received: 1, transit: transit(now_us, ts, state)}

        max ->
          ext = extend(seq, max)

          cond do
            ext > max ->
              state = %{state | received: state.received + 1} |> jitter(now_us, ts)
              gap(state, max, ext)

            Map.has_key?(state.missing, ext) ->
              %{
                state
                | received: state.received + 1,
                  recovered: state.recovered + 1,
                  missing: Map.delete(state.missing, ext)
              }

            true ->
              %{state | duplicates: state.duplicates + 1}
          end
      end

    {actions, state} = nack(state)
    {actions ++ [buffer: {:output, buffer}], state}
  end

  # Missing packets between the previous highest and this one.
  defp gap(state, max, ext) when ext == max + 1, do: %{state | max: ext}

  defp gap(state, max, ext) when ext - max - 1 > @max_gap,
    # A jump this big is a restarted sender, not loss worth NACKing.
    do: %{state | max: ext}

  defp gap(state, max, ext) do
    missing = for i <- (max + 1)..(ext - 1), into: state.missing, do: {i, :new}
    %{state | max: ext, missing: missing}
  end

  defp nack(%{opts: %{nack: true}} = state) do
    case for({ext, :new} <- state.missing, do: ext) do
      [] ->
        {[], state}

      new ->
        seqs = new |> Enum.sort() |> Enum.take(-@nack_max) |> Enum.map(&(&1 &&& 0xFFFF))
        nack = NACK.from_sequence_numbers(state.own_ssrc, state.opts.ssrc, seqs)
        missing = Map.new(state.missing, fn {ext, _} -> {ext, :nacked} end)
        {[feedback([nack])], %{state | missing: missing, nacked: state.nacked + length(seqs)}}
    end
  end

  defp nack(state) do
    {[], %{state | missing: Map.new(state.missing, fn {ext, _} -> {ext, :seen} end)}}
  end

  # The extended sequence number closest to the highest one seen so far.
  defp extend(seq, max) do
    candidate = (max &&& bnot(0xFFFF)) ||| seq

    cond do
      candidate - max > 0x8000 -> candidate - 0x10000
      max - candidate > 0x8000 -> candidate + 0x10000
      true -> candidate
    end
  end

  # RFC 3550 A.8, in RTP timestamp units.
  defp transit(now_us, ts, state), do: div(now_us * state.opts.clock_rate, 1_000_000) - ts

  defp jitter(state, now_us, ts) do
    transit = transit(now_us, ts, state)
    d = abs(transit - state.transit)
    # A wrapped RTP timestamp shows up as a huge step: skip it.
    if d > 0x7FFFFFFF,
      do: %{state | transit: transit},
      else: %{state | transit: transit, jitter: state.jitter + (d - state.jitter) / 16}
  end

  defp sender_report(payload, state) do
    ssrc = state.opts.ssrc

    with {:ok, packets} <- ExRTCP.CompoundPacket.decode(payload),
         %SenderReport{ntp_timestamp: ntp} <-
           Enum.find(packets, &match?(%SenderReport{ssrc: ^ssrc}, &1)) do
      %{state | lsr: {RTCP.middle32(ntp), System.monotonic_time(:millisecond)}}
    else
      _ -> state
    end
  end

  defp feedback(packets),
    do: {:buffer, {:feedback, %Buffer{payload: ExRTCP.CompoundPacket.encode(packets)}}}

  defp stats(state) do
    expected = state.max - state.base + 1

    %{
      packets: state.received,
      expected: expected,
      lost: max(0, expected - state.received),
      fraction_lost: Float.round(state.fraction_lost / 256, 3),
      jitter_ms: Float.round(state.jitter * 1_000 / state.opts.clock_rate, 2),
      nacked: state.nacked,
      recovered: state.recovered,
      duplicates: state.duplicates,
      keyframe_requests: state.plis
    }
  end
end
