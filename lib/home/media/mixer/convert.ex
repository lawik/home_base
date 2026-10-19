defmodule Home.Media.Mixer.Convert do
  @moduledoc """
  Cheap s16le format conversion for a mixer input whose format differs from the mix:
  channels are averaged down to mono or copied up from it (otherwise the first ones are
  kept, the last one repeated), and the sample rate is changed by linear interpolation,
  carried across buffers so there is no seam between them. Fine for speech and alerts
  into a speaker; not a high-quality resampler.
  """

  alias Membrane.RawAudio

  defstruct [:from, :to, :step, pos: 0.0, prev: nil]

  @opaque t :: %__MODULE__{}

  @doc "A converter from `from` to `to`, both `%RawAudio{sample_format: :s16le}`."
  @spec new(RawAudio.t(), RawAudio.t()) :: t()
  def new(%RawAudio{sample_format: :s16le} = from, %RawAudio{sample_format: :s16le} = to),
    do: %__MODULE__{from: from, to: to, step: from.sample_rate / to.sample_rate}

  def new(from, to),
    do: raise(ArgumentError, "can't convert #{inspect(from)} to #{inspect(to)}")

  @doc "Convert one buffer's payload; returns the payload and the converter for the next."
  @spec run(t(), binary()) :: {binary(), t()}
  def run(%__MODULE__{} = c, payload) do
    frames = payload |> frames(c.from.channels) |> Enum.map(&channels(&1, c.to.channels))

    if c.from.sample_rate == c.to.sample_rate,
      do: {encode(frames), c},
      else: resample(c, frames)
  end

  defp frames(payload, n) do
    size = 2 * n

    for <<frame::binary-size(^size) <- payload>>,
      do: for(<<s::signed-little-16 <- frame>>, do: s)
  end

  defp channels(frame, n) when length(frame) == n, do: frame
  defp channels(frame, 1), do: [div(Enum.sum(frame), length(frame))]
  defp channels([s], n), do: List.duplicate(s, n)

  defp channels(frame, n) when length(frame) > n, do: Enum.take(frame, n)
  defp channels(frame, n), do: frame ++ List.duplicate(List.last(frame), n - length(frame))

  # Output samples sit at input positions pos, pos + step, ...; position -1 is the last
  # frame of the previous buffer.
  defp resample(c, []), do: {<<>>, c}

  defp resample(c, frames) do
    input = List.to_tuple(if c.prev, do: [c.prev | frames], else: frames)
    offset = if c.prev, do: 1, else: 0
    last = tuple_size(input) - 1 - offset
    {out, pos} = interpolate(input, offset, c.pos, c.step, last, [])
    {encode(Enum.reverse(out)), %{c | pos: pos - (last + 1), prev: List.last(frames)}}
  end

  defp interpolate(input, offset, pos, step, last, acc) when pos <= last do
    i = floor(pos)
    a = pos - i
    x0 = elem(input, i + offset)
    x1 = if i + 1 <= last, do: elem(input, i + 1 + offset), else: x0
    frame = Enum.zip_with(x0, x1, fn s0, s1 -> round(s0 + (s1 - s0) * a) end)
    interpolate(input, offset, pos + step, step, last, [frame | acc])
  end

  defp interpolate(_input, _offset, pos, _step, _last, acc), do: {acc, pos}

  defp encode(frames) do
    for frame <- frames, s <- frame, into: <<>>, do: <<clamp(s)::signed-little-16>>
  end

  defp clamp(s), do: s |> max(-32_768) |> min(32_767)
end
