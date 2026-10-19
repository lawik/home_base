defmodule Home.Media.H264Payloader do
  @moduledoc """
  RTP H.264 payloader (RFC 6184, non-interleaved mode) that takes whole access units and
  sends each one out as soon as it arrives.

  `Membrane.RTP.H264.Payloader` takes NAL units and gathers small ones into a STAP-A
  until a NAL unit of the next frame shows up, so the end of every frame (and with small
  frames the whole frame) leaves one frame interval late. Here an access unit's NAL units
  go out at once: runs of small ones as STAP-A, ones too big for a packet as FU-A, the
  rest as single NAL unit packets, with the RTP marker on the last packet (RFC 6184
  §5.1), which `Home.Media.H264Depayloader` uses to end the access unit at the receiver.
  """

  use Membrane.Filter

  alias Membrane.{Buffer, H264, RTP}
  alias Membrane.RTP.H264.{FU, StapA}

  def_input_pad :input, accepted_format: %H264{alignment: :au, stream_structure: :annexb}
  def_output_pad :output, accepted_format: %RTP{payload_format: H264}

  def_options max_payload_size: [
                spec: pos_integer(),
                default: 1_200,
                description: "Largest RTP payload, in bytes."
              ]

  @impl true
  def handle_init(_ctx, opts), do: {[], %{max: opts.max_payload_size}}

  @impl true
  def handle_stream_format(:input, _format, _ctx, state),
    do: {[stream_format: {:output, %RTP{payload_format: H264}}], state}

  @impl true
  def handle_buffer(:input, %Buffer{} = au, _ctx, state) do
    payloads = au.payload |> nalus() |> packetize(state.max)
    last = length(payloads) - 1

    buffers =
      for {payload, i} <- Enum.with_index(payloads) do
        %Buffer{
          payload: payload,
          pts: au.pts,
          dts: au.dts,
          metadata: %{rtp: %{marker: i == last}}
        }
      end

    {[buffer: {:output, buffers}], state}
  end

  @doc false
  # NAL units of an Annex B byte stream, without start codes.
  def nalus(payload) do
    payload
    |> :binary.split([<<0, 0, 0, 1>>, <<0, 0, 1>>], [:global])
    |> Enum.reject(&(&1 == ""))
  end

  defp packetize(nalus, max), do: packetize(nalus, max, [], [])

  defp packetize([], _max, stap, acc), do: Enum.reverse(flush(stap, acc))

  defp packetize([nalu | rest], max, stap, acc) when byte_size(nalu) > max do
    packetize(rest, max, [], Enum.reverse(FU.serialize(nalu, max), flush(stap, acc)))
  end

  defp packetize([nalu | rest], max, stap, acc) do
    size = Enum.reduce(stap, 1, &(StapA.aggregation_unit_size(&1) + &2))

    if stap == [] or size + StapA.aggregation_unit_size(nalu) <= max,
      do: packetize(rest, max, [nalu | stap], acc),
      else: packetize(rest, max, [nalu], flush(stap, acc))
  end

  defp flush([], acc), do: acc
  defp flush([nalu], acc), do: [nalu | acc]

  # `stap` is in reverse order, as `StapA.serialize/3` wants it.
  defp flush(stap, acc) do
    f = stap |> Enum.map(fn <<f::1, _::bitstring>> -> f end) |> Enum.max()
    nri = stap |> Enum.map(fn <<_::1, nri::2, _::bitstring>> -> nri end) |> Enum.max()
    [StapA.serialize(stap, f, nri) | acc]
  end
end
