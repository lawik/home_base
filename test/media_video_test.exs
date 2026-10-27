defmodule Home.MediaVideoTest do
  use ExUnit.Case, async: false

  alias Home.Media.Video
  alias Home.Media.Video.{Format, Path}

  @all [:constrained_baseline, :baseline, :main, :high]

  # A Fairphone 3's Venus as its driver reports it.
  @venus %Format{
    hardware: true,
    element: Membrane.V4L2.H264.Decoder,
    name: "Venus",
    profiles: @all,
    max_level: 51,
    max_size: {4096, 4096}
  }

  @small_hw %Format{
    hardware: true,
    element: :software,
    name: "small",
    profiles: [:constrained_baseline, :baseline],
    max_size: {640, 480}
  }

  # A phone camera: Venus encodes what the ISP gives it, at a few sizes.
  @phone_camera %Format{
    hardware: true,
    element: :relay,
    name: "Venus",
    profiles: [:baseline],
    sizes: [{1920, 1080}, {1280, 720}, {640, 360}],
    size: {1280, 720},
    fps: 30,
    max_fps: 30,
    bitrate: 1_000_000,
    max_bitrate: 1_000_000
  }

  defp x264(w, h, fps \\ 30), do: Video.software_encoder(%{w: w, h: h, fps: fps})
  defp display(decoders, pref \\ :auto, ref \\ {:b, "disp"}), do: {ref, decoders, pref}

  test "levels" do
    assert Video.level({1280, 720}, 30) == 31
    assert Video.level({1920, 1080}, 30) == 40
    assert Video.level({1920, 1080}, 60) == 42
    assert Video.level({3840, 2160}, 30) == 51
    assert Video.level({320, 240}, 30) == 13
    assert Video.level(nil, 30) == nil
    assert Video.level({1280, 720}, nil) == nil
  end

  describe "negotiate/3" do
    test "x264 to a hardware decoder: hardware, the camera's size and rate" do
      assert {:ok, %Path{} = path} =
               Video.negotiate([x264(1280, 720)], [
                 display([@venus, Video.software_decoder()])
               ])

      assert path.profile == :constrained_baseline
      assert path.size == {1280, 720}
      assert path.fps == 30
      assert path.level == 31
      assert path.bitrate == 3_000_000
      assert path.encoder.name == "x264"
      assert path.decoders == %{{:b, "disp"} => @venus}
    end

    test "with hardware there, :auto doesn't fall back to software" do
      decoders = [%{@venus | profiles: [:main]}, Video.software_decoder()]

      assert {:error, {:no_video_path, [failure]}} =
               Video.negotiate([@phone_camera], [display(decoders)])

      assert failure == %{
               sink: {:b, "disp"},
               decoder: "Venus",
               reason: {:profile, :baseline, [:main]}
             }

      # The override decodes in software.
      assert {:ok, path} = Video.negotiate([@phone_camera], [display(decoders, :software)])
      assert %{{:b, "disp"} => %Format{name: "FFmpeg", hardware: false}} = path.decoders
    end

    test "a node with only software decodes in software; :hardware refuses it" do
      software = [Video.software_decoder()]
      assert {:ok, path} = Video.negotiate([@phone_camera], [display(software)])
      assert %{{:b, "disp"} => %Format{name: "FFmpeg"}} = path.decoders

      assert {:error, {:no_video_path, [%{reason: {:no_decoder, :hardware}}]}} =
               Video.negotiate([@phone_camera], [display(software, :hardware)])
    end

    test "a relay picks the largest of its sizes every decoder takes" do
      assert {:ok, path} =
               Video.negotiate([@phone_camera], [display([%{@venus | max_size: {640, 480}}])])

      assert path.size == {640, 360}
      assert path.level == 30

      # Its default is 1280×720; asked for 1080p and a decoder that takes it, it sends it.
      assert {:ok, %{size: {1280, 720}}} = Video.negotiate([@phone_camera], [display([@venus])])

      assert {:ok, %{size: {1920, 1080}}} =
               Video.negotiate([@phone_camera], [display([@venus])], size: {1920, 1080})
    end

    test "a relay sends the frame rate asked for, up to its own, and its bitrate cap holds" do
      assert {:ok, path} =
               Video.negotiate([@phone_camera], [display([@venus])], fps: 15, bitrate: 2_000_000)

      assert path.fps == 15
      assert path.bitrate == 1_000_000

      assert {:ok, %{fps: 30}} = Video.negotiate([@phone_camera], [display([@venus])], fps: 60)
    end

    test "a sink that wants a small, thin stream gets one, made so at the source" do
      camera = %{@phone_camera | sizes: [{1280, 720}, {640, 360}, {384, 216}]}

      watch = %Format{
        hardware: true,
        element: :software,
        name: "watch",
        max_size: {400, 400},
        max_bitrate: 250_000
      }

      assert {:ok, path} = Video.negotiate([camera], [display([watch])])
      assert path.size == {384, 216}
      assert path.bitrate == 250_000

      # x264 scales to it.
      assert {:ok, %{size: {400, 224}, bitrate: 250_000}} =
               Video.negotiate([x264(1280, 720)], [display([watch])])

      # With a phone on the same stream, the watch sets it for both.
      sinks = [display([@venus], :auto, {:b, "phone"}), display([watch], :auto, {:c, "watch"})]
      assert {:ok, %{size: {384, 216}, bitrate: 250_000}} = Video.negotiate([camera], sinks)

      # A stream already running at 1 Mbit/s is too much for it.
      {:ok, running} = Video.negotiate([camera], [display([@venus])], size: {384, 216})

      assert {:error, {:no_video_path, [%{reason: {:bitrate, 1_000_000, 250_000}} = failure]}} =
               Video.accepts([watch], running)

      assert Video.explain([failure]) == [
               "watch: takes up to 250 kbit/s, the stream is 1.0 Mbit/s"
             ]
    end

    test "x264 scales down to fit, keeping the picture's shape" do
      assert {:ok, path} = Video.negotiate([x264(1920, 1080)], [display([@small_hw])])
      assert path.size == {640, 360}
      assert path.decoders == %{{:b, "disp"} => @small_hw}
    end

    test "x264 steps down to a size whose level the decoder takes" do
      decoder = %{@venus | max_level: 31}
      assert {:ok, path} = Video.negotiate([x264(1920, 1080)], [display([decoder])])
      assert path.size == {1280, 720}
      assert path.level == 31
    end

    test "a stream nothing on a sink takes: the reasons, per decoder" do
      fixed = %{@phone_camera | sizes: [{1920, 1080}], size: {1920, 1080}}
      decoder = %{@venus | max_level: 31}

      assert {:error, {:no_video_path, [failure]} = error} =
               Video.negotiate([fixed], [display([decoder])])

      assert failure.reason == {:level, 40, 31}
      assert [line] = Video.explain(error)
      assert line =~ "level 3.1"
      assert line =~ "needs 4.0"
    end

    test "one stream for every sink: the smallest decoder sets the size" do
      sinks = [display([@venus], :auto, {:b, "big"}), display([@small_hw], :auto, {:c, "small"})]
      assert {:ok, path} = Video.negotiate([x264(1280, 720)], sinks)
      assert path.size == {640, 360}
      assert path.decoders == %{{:b, "big"} => @venus, {:c, "small"} => @small_hw}
    end

    test "hardware encoders first" do
      assert {:ok, path} =
               Video.negotiate([x264(1280, 720), @phone_camera], [display([@venus])])

      assert path.encoder.name == "Venus"
    end

    test "unknown limits match anything" do
      unknown = %Format{element: :relay}
      assert {:ok, path} = Video.negotiate([unknown], [display([@venus])])
      assert %{profile: nil, size: nil, level: nil} = path
    end

    test "no encoder" do
      assert {:error, {:no_video_path, [%{reason: :no_encoder}]}} =
               Video.negotiate([], [display([@venus])])
    end
  end

  test "accepts/4: a sink joining a settled stream" do
    {:ok, path} = Video.negotiate([@phone_camera], [display([@venus])])

    assert {:ok, @venus} = Video.accepts([@venus], path)

    assert {:error, {:no_video_path, [%{sink: {:c, "small"}, reason: {:size, {1280, 720}, _}}]}} =
             Video.accepts([%{@venus | max_size: {640, 480}}], path, :auto, {:c, "small"})

    assert {:ok, %Format{name: "FFmpeg"}} =
             Video.accepts(
               [%{@venus | max_size: {640, 480}}, Video.software_decoder()],
               path,
               :software
             )
  end

  test "describe/1" do
    {:ok, path} = Video.negotiate([@phone_camera], [display([@venus])])

    assert Video.describe(path) ==
             "H.264 baseline 1280×720 30 fps level 3.1 1.0 Mbit/s, Venus (hardware) to Venus (hardware)"

    assert Video.describe(@venus) =~
             "Venus (hardware): H.264 constrained baseline/baseline/main/high"
  end

  describe "decoders/0" do
    setup do
      saved = :persistent_term.get({Home, :config}, nil)

      on_exit(fn ->
        if saved,
          do: :persistent_term.put({Home, :config}, saved),
          else: :persistent_term.erase({Home, :config})
      end)
    end

    defp config(video), do: :persistent_term.put({Home, :config}, video: video)

    test "configured hardware decoders, then software" do
      config(decoders: [[element: Membrane.V4L2.H264.Decoder, name: "Venus", max_level: 51]])

      assert [%Format{hardware: true, name: "Venus", max_level: 51}, %Format{name: "FFmpeg"}] =
               Video.decoders()

      assert Home.Media.video_decoder() == Membrane.V4L2.H264.Decoder
    end

    test "the older decoder: option, and software: false" do
      config(decoder: Membrane.V4L2.H264.Decoder, software: false)

      assert [%Format{hardware: true, element: Membrane.V4L2.H264.Decoder, profiles: nil}] =
               Video.decoders()

      config([])
      assert [%Format{name: "FFmpeg"}] = Video.decoders()
      assert Home.Media.video_decoder() == :software
    end
  end
end
