defmodule Home.Media.H264Relay do
  @moduledoc """
  Membrane source for video that arrives already encoded as H.264, e.g. an IP camera's
  RTSP stream pulled by `Home.Onvif.Relay`. A source pipeline with this endpoint skips
  the decode/encode stages and only re-packetizes (`Home.Media.SourcePipeline`).

  `feed` is a process on this node that fans one stream out to many such sources. On
  playing, the element monitors it and calls `GenServer.call(feed, {:subscribe, self()})`;
  from then on the feed sends

      {:h264_relay, feed, {:au, annexb_payload, pts_ns, keyframe?}}

  one message per access unit, starting at a keyframe (with SPS/PPS) and with
  monotonic `pts_ns`. The feed monitors the element and forgets it when it goes. If the
  feed is gone (or goes), the element ends its stream; whoever owns the feed ends the
  media session (for `Home.Onvif.Relay`, the capability's lease is revoked or its server
  goes down).

  Output: `%Membrane.H264{alignment: :au, stream_structure: :annexb}`.
  """

  use Membrane.Source

  def_output_pad(:output,
    accepted_format: %Membrane.H264{alignment: :au, stream_structure: :annexb},
    flow_control: :push
  )

  def_options(
    feed: [spec: GenServer.server(), description: "The process fanning the stream out."]
  )

  @impl true
  def handle_init(_ctx, opts), do: {[], %{feed: opts.feed, monitor: nil}}

  @impl true
  def handle_playing(_ctx, state) do
    format = %Membrane.H264{alignment: :au, stream_structure: :annexb}
    monitor = Process.monitor(state.feed)

    try do
      :ok = GenServer.call(state.feed, {:subscribe, self()})
      {[stream_format: {:output, format}], %{state | monitor: monitor}}
    catch
      :exit, _ -> {[stream_format: {:output, format}, end_of_stream: :output], state}
    end
  end

  @impl true
  def handle_info({:h264_relay, _feed, {:au, payload, pts, keyframe?}}, _ctx, state) do
    buffer = %Membrane.Buffer{
      payload: payload,
      pts: pts,
      dts: pts,
      metadata: %{h264: %{key_frame?: keyframe?}}
    }

    {[buffer: {:output, buffer}], state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, ctx, %{monitor: ref} = state) do
    if ctx.pads.output.end_of_stream?,
      do: {[], state},
      else: {[end_of_stream: :output], state}
  end

  def handle_info(_msg, _ctx, state), do: {[], state}
end
