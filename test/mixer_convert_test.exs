defmodule Home.MixerConvertTest do
  use ExUnit.Case, async: true

  alias Home.Media.Mixer.Convert
  alias Membrane.RawAudio

  defp format(rate, channels),
    do: %RawAudio{sample_format: :s16le, sample_rate: rate, channels: channels}

  defp pcm(samples), do: for(s <- samples, into: <<>>, do: <<s::signed-little-16>>)
  defp samples(pcm), do: for(<<s::signed-little-16 <- pcm>>, do: s)

  test "mono to stereo and back" do
    up = Convert.new(format(48_000, 1), format(48_000, 2))
    assert {out, _} = Convert.run(up, pcm([100, -200]))
    assert samples(out) == [100, 100, -200, -200]

    down = Convert.new(format(48_000, 2), format(48_000, 1))
    assert {out, _} = Convert.run(down, pcm([100, 300, -200, -400]))
    assert samples(out) == [200, -300]
  end

  test "resampling keeps the length and the waveform across buffers" do
    c = Convert.new(format(16_000, 1), format(48_000, 1))
    # A 16 kHz ramp in 10 ms buffers becomes a 48 kHz ramp three times as long, with no
    # seam where the buffers meet.
    ramp = Enum.map(0..479, &(&1 * 10))

    {out, _c} =
      ramp
      |> Enum.chunk_every(160)
      |> Enum.reduce({[], c}, fn chunk, {acc, c} ->
        {pcm, c} = Convert.run(c, pcm(chunk))
        {acc ++ samples(pcm), c}
      end)

    assert_in_delta length(out), 3 * 480, 3
    steps = out |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [x, y] -> y - x end)
    assert Enum.all?(steps, &(&1 in 3..4))
  end

  test "48 kHz stereo to 44.1 kHz mono" do
    c = Convert.new(format(48_000, 2), format(44_100, 1))
    {out, _} = Convert.run(c, pcm(List.duplicate(1_000, 960 * 2)))
    assert_in_delta byte_size(out) / 2, 882, 1
    assert Enum.all?(samples(out), &(&1 == 1_000))
  end

  test "only s16le" do
    assert_raise ArgumentError, fn ->
      Convert.new(
        %RawAudio{sample_format: :f32le, sample_rate: 48_000, channels: 1},
        format(48_000, 1)
      )
    end
  end
end
