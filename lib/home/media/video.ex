defmodule Home.Media.Video do
  @moduledoc """
  What video each node can send and show, and how a video session settles its stream
  between them (§5.2).

  ## What a capability can do

  Every `:video_in` and `:display` capability carries its video support in its registry
  info (`Home.Registry.list/1`, `info.video`), as `Home.Media.Video.Format`s:

      # a :video_in
      %{encode: [%Format{hardware: true, element: :relay, name: "Venus",
                         profiles: [:baseline], sizes: [{1920, 1080}, {1280, 720}], ...}]}

      # a :display
      %{decode: [%Format{hardware: true, element: Membrane.V4L2.H264.Decoder,
                         name: "Venus", max_level: 51, ...},
                 %Format{hardware: false, element: :software, name: "FFmpeg", ...}]}

  They're worked out on the capability's node:

    * An adapter that knows says so with the optional `c:Home.Adapter.video/1` callback,
      e.g. a camera whose stream comes encoded by its own hardware (`Home.Onvif.Camera`).
    * Any other `:video_in` sends raw frames, which x264 encodes on its node
      (`software_encoder/1`, at the size and frame rate in its meta).
    * A `:display` decodes with its node's decoders (`decoders/0`): the hardware ones in
      `config :home_base, video: [decoders: [...]]`, and FFmpeg's software decoder.

  `list/1` gathers them across the cluster.

  ## Negotiation

  A video session (`Home.Media.Session` with `codec: :h264`) settles its stream with
  `negotiate/3` before it starts anything: a profile, size, frame rate and bitrate that
  the source can make and every sink can decode. The source then sends exactly that: x264
  is set to the profile and scaled to the size, and a relay source gets them as its
  parameters (see `Home.Media.H264Relay`). A sink added later has to take the stream as it
  is (`accepts/4`). Without such a stream the session doesn't start, or the sink isn't
  added: `{:error, {:no_video_path, reasons}}`, one `%{sink:, decoder:, reason:}` per
  decoder that was tried (`explain/1` puts them in words).

  Each sink decodes with one of its node's decoders, as the session's `:decoder` option
  says:

    * `:auto` (default) - the node's hardware decoders if it has any, otherwise its
      software decoder. A display with a hardware decoder doesn't fall back to software
      on its own: a stream its hardware can't take is a failure, not a slow picture.
    * `:software` - the software decoder, even where there is hardware: the override
      for a device that asks for it. It changes what that sink decodes with, not what the
      source sends.
    * `:hardware` - only hardware, even on a node that has only software.

  `check/3` runs the negotiation for capability refs without leasing anything.
  """

  alias Home.Media.Video.{Format, Path}

  @profiles [:constrained_baseline, :baseline, :main, :high]
  @default_bitrate 3_000_000

  # H.264 levels (Table A-1): level_idc, macroblocks per second, macroblocks per frame.
  @levels [
    {10, 1_485, 99},
    {11, 3_000, 396},
    {12, 6_000, 396},
    {13, 11_880, 396},
    {20, 11_880, 396},
    {21, 19_800, 792},
    {22, 20_250, 1_620},
    {30, 40_500, 1_620},
    {31, 108_000, 3_600},
    {32, 216_000, 5_120},
    {40, 245_760, 8_192},
    {41, 245_760, 8_192},
    {42, 522_240, 8_704},
    {50, 589_824, 22_080},
    {51, 983_040, 36_864},
    {52, 2_073_600, 36_864},
    {60, 4_177_920, 139_264},
    {61, 8_355_840, 139_264},
    {62, 16_711_680, 139_264}
  ]

  # Heights a scaling encoder steps down through when the size it was asked for doesn't
  # fit a decoder.
  @ladder [1080, 720, 540, 360, 240, 180]

  @type preference :: :auto | :hardware | :software
  @type sink :: {Home.Capability.ref() | nil, [Format.t()], preference()}
  @type failure :: %{sink: Home.Capability.ref() | nil, decoder: String.t() | nil, reason: term()}

  ## Support

  @doc "The software decoder every node has: FFmpeg, then RGB."
  @spec software_decoder() :: Format.t()
  def software_decoder,
    do: %Format{hardware: false, element: :software, name: "FFmpeg", profiles: @profiles}

  @doc """
  x264 on a `:video_in`'s node, for a capability that sends raw frames: `meta`'s `w` and
  `h` are its size (it scales down, never up) and `fps` its frame rate.
  """
  @spec software_encoder(map()) :: Format.t()
  def software_encoder(meta \\ %{}) do
    size =
      case meta do
        %{w: w, h: h} when is_integer(w) and is_integer(h) -> {w, h}
        _ -> nil
      end

    fps = Map.get(meta, :fps)

    %Format{
      hardware: false,
      element: :software,
      name: "x264",
      profiles: @profiles,
      size: size,
      max_size: size,
      fps: fps,
      max_fps: fps,
      bitrate: @default_bitrate
    }
  end

  @doc """
  This node's decoders: those in `config :home_base, video: [decoders: [...]]` (formats,
  or maps or keyword lists of their fields; `hardware` defaults to true there), then the
  software decoder unless `software: false`.

  The older `video: [decoder: module | {module, opts}]` is one hardware decoder with no
  known limits, and `decoder: :software` none.
  """
  @spec decoders() :: [Format.t()]
  def decoders do
    config = Home.config(:video, [])

    hardware =
      case Keyword.fetch(config, :decoders) do
        {:ok, decoders} ->
          for fields <- decoders, do: fields |> configured() |> Format.new()

        :error ->
          case Keyword.get(config, :decoder, :software) do
            :software -> []
            element -> [%Format{hardware: true, element: element, name: element_name(element)}]
          end
      end

    if Keyword.get(config, :software, true), do: hardware ++ [software_decoder()], else: hardware
  end

  defp configured(%Format{} = format), do: format
  defp configured(fields), do: fields |> Map.new() |> Map.put_new(:hardware, true)

  @doc false
  # The `video:` of a capability's registry info, worked out on its node.
  def support(%Home.Capability{kind: kind} = cap, adapter, astate)
      when kind in [:video_in, :display] do
    formats =
      cond do
        function_exported?(adapter, :video, 1) -> adapter.video(astate)
        kind == :video_in -> [software_encoder(cap.meta)]
        true -> decoders()
      end

    formats = Enum.map(formats, &Format.new/1)
    if kind == :video_in, do: %{encode: formats}, else: %{decode: formats}
  end

  def support(_cap, _adapter, _astate), do: nil

  @doc false
  # The formats in a capability's registry info. A node running a home_base from before
  # video support has none: its cameras are x264's, and its displays decode their own way.
  def formats(%{video: %{encode: formats}}, :encode), do: formats
  def formats(%{video: %{decode: formats}}, :decode), do: formats
  def formats(%{cap: cap}, :encode), do: [software_encoder(cap.meta)]
  def formats(_info, :encode), do: [software_encoder()]
  def formats(_info, :decode), do: [%Format{name: "unknown"}]

  @doc """
  The lowest H.264 level (`level_idc`) a picture of `size` at `fps` needs; nil if either
  is unknown or it's past every level.
  """
  @spec level(Format.size() | nil, pos_integer() | nil) :: pos_integer() | nil
  def level(nil, _fps), do: nil
  def level(_size, nil), do: nil

  def level({w, h}, fps) do
    mbs = div(w + 15, 16) * div(h + 15, 16)

    Enum.find_value(@levels, fn {level, per_second, per_frame} ->
      if mbs <= per_frame and mbs * fps <= per_second, do: level
    end)
  end

  ## Negotiation

  @doc """
  Settle a stream from one of `encoders` (the source's formats) to every sink, each
  `{ref, decoders, preference}`. `request` may ask for a `:size`, `:fps` and `:bitrate`;
  otherwise the encoder's defaults go.

  Encoders are tried hardware first; for each, its profiles in its order and sizes from
  the one wanted down. Returns the first stream every sink takes, or the reasons the
  first one tried didn't work.
  """
  @spec negotiate([Format.t() | map()], [sink()], keyword() | map()) ::
          {:ok, Path.t()} | {:error, {:no_video_path, [failure()]}}
  def negotiate(encoders, sinks, request \\ []) do
    request = Map.new(request)

    encoders
    |> Enum.map(&Format.new/1)
    |> Enum.sort_by(&(not &1.hardware))
    |> Enum.reduce_while([], fn encoder, failures ->
      case settle(encoder, sinks, request) do
        {:ok, path} -> {:halt, {:ok, path}}
        {:error, more} -> {:cont, failures ++ more}
      end
    end)
    |> case do
      {:ok, path} -> {:ok, path}
      [] -> {:error, {:no_video_path, [%{sink: nil, decoder: nil, reason: :no_encoder}]}}
      failures -> {:error, {:no_video_path, failures}}
    end
  end

  @doc """
  Whether a sink with `decoders` can join a stream already settled as `path`, decoding
  as `preference` says: `{:ok, decoder}`, or `{:error, {:no_video_path, reasons}}`. The
  stream's bitrate is set by then, so a decoder that wants less (`max_bitrate`) can't.
  """
  @spec accepts([Format.t() | map()], Path.t(), preference(), Home.Capability.ref() | nil) ::
          {:ok, Format.t()} | {:error, {:no_video_path, [failure()]}}
  def accepts(decoders, %Path{} = path, preference \\ :auto, ref \\ nil) do
    stream = Map.take(path, [:codec, :profile, :size, :fps, :level, :bitrate])

    case candidates(decoders, preference, path.codec) do
      [] ->
        {:error,
         {:no_video_path, [%{sink: ref, decoder: nil, reason: {:no_decoder, preference}}]}}

      candidates ->
        case pick_decoders([{ref, candidates, preference}], stream) do
          {:ok, %{^ref => decoder}} -> {:ok, decoder}
          {:error, failures} -> {:error, {:no_video_path, failures}}
        end
    end
  end

  defp settle(encoder, sinks, request) do
    sinks =
      for {ref, decoders, pref} <- sinks,
          do: {ref, candidates(decoders, pref, encoder.codec), pref}

    case for({ref, [], pref} <- sinks, do: no_decoder(ref, pref)) do
      [] ->
        fps = fps(encoder, request)
        bitrate = bitrate(encoder, request)

        attempts =
          for profile <- encoder.profiles || [nil],
              size <- sizes(encoder, request, sinks),
              do: {profile, size}

        try_attempts(attempts, encoder, sinks, fps, bitrate, nil)

      missing ->
        {:error, missing}
    end
  end

  defp no_decoder(ref, pref), do: %{sink: ref, decoder: nil, reason: {:no_decoder, pref}}

  defp try_attempts([], _encoder, _sinks, _fps, _bitrate, failures), do: {:error, failures || []}

  defp try_attempts([{profile, size} | rest], encoder, sinks, fps, bitrate, first) do
    stream = %{
      codec: encoder.codec,
      profile: profile,
      size: size,
      fps: fps,
      level: level(size, fps)
    }

    result =
      if at_most?(stream.level, encoder.max_level),
        do: pick_decoders(sinks, stream),
        else:
          {:error,
           [
             %{
               sink: nil,
               decoder: label(encoder),
               reason: {:level, stream.level, encoder.max_level}
             }
           ]}

    case result do
      {:ok, decoders} ->
        path = %Path{
          codec: stream.codec,
          profile: profile,
          size: size,
          fps: fps,
          level: stream.level,
          # No more than any sink wants to receive.
          bitrate: min_of([bitrate | Enum.map(Map.values(decoders), & &1.max_bitrate)]),
          encoder: encoder,
          decoders: decoders
        }

        {:ok, path}

      {:error, failures} ->
        try_attempts(rest, encoder, sinks, fps, bitrate, first || failures)
    end
  end

  # Each sink's first decoder that takes the stream.
  defp pick_decoders(sinks, stream) do
    {chosen, failures} =
      Enum.reduce(sinks, {%{}, []}, fn {ref, candidates, _pref}, {chosen, failures} ->
        case Enum.find(candidates, &(takes(&1, stream) == :ok)) do
          nil ->
            refused =
              for decoder <- candidates,
                  {:error, reason} <- [takes(decoder, stream)],
                  do: %{sink: ref, decoder: label(decoder), reason: reason}

            {chosen, failures ++ refused}

          decoder ->
            {Map.put(chosen, ref, decoder), failures}
        end
      end)

    if failures == [], do: {:ok, chosen}, else: {:error, failures}
  end

  @doc false
  # Whether `decoder` takes `stream` (`%{codec, profile, size, fps, level}`, and the
  # `bitrate` of one already running; a stream being settled is capped to the decoder's
  # instead).
  def takes(%Format{} = decoder, stream) do
    cond do
      decoder.codec != stream.codec ->
        {:error, {:codec, stream.codec}}

      not takes_profile?(decoder.profiles, stream.profile) ->
        {:error, {:profile, stream.profile, decoder.profiles}}

      not fits?(stream.size, decoder.max_size) ->
        {:error, {:size, stream.size, decoder.max_size}}

      not at_most?(stream.fps, decoder.max_fps) ->
        {:error, {:fps, stream.fps, decoder.max_fps}}

      not at_most?(stream.level, decoder.max_level) ->
        {:error, {:level, stream.level, decoder.max_level}}

      not at_most?(stream[:bitrate], decoder.max_bitrate) ->
        {:error, {:bitrate, stream.bitrate, decoder.max_bitrate}}

      true ->
        :ok
    end
  end

  # A constrained baseline stream is a baseline, main and high one too.
  defp takes_profile?(nil, _profile), do: true
  defp takes_profile?(_profiles, nil), do: true

  defp takes_profile?(profiles, :constrained_baseline),
    do: Enum.any?([:constrained_baseline, :baseline, :main, :high], &(&1 in profiles))

  defp takes_profile?(profiles, profile), do: profile in profiles

  defp fits?(nil, _max), do: true
  defp fits?(_size, nil), do: true
  defp fits?({w, h}, {max_w, max_h}), do: w <= max_w and h <= max_h

  defp at_most?(nil, _max), do: true
  defp at_most?(_value, nil), do: true
  defp at_most?(value, max), do: value <= max

  defp candidates(decoders, preference, codec) do
    decoders = decoders |> Enum.map(&Format.new/1) |> Enum.filter(&(&1.codec == codec))
    {hardware, software} = Enum.split_with(decoders, & &1.hardware)

    case preference do
      :software -> software
      :hardware -> hardware
      _auto -> if hardware != [], do: hardware, else: software
    end
  end

  # x264 sends at its camera's rate. An encoder told its rate sends what's asked, up to
  # what it can.
  defp fps(%Format{element: :software, fps: fps}, _request) when fps != nil, do: fps

  defp fps(encoder, request),
    do: min_of([Map.get(request, :fps) || encoder.fps || encoder.max_fps, encoder.max_fps])

  defp bitrate(encoder, request) do
    default = if encoder.element == :software, do: @default_bitrate
    min_of([Map.get(request, :bitrate) || encoder.bitrate || default, encoder.max_bitrate])
  end

  # Largest first, none larger than the one wanted.
  defp sizes(%Format{sizes: sizes} = encoder, request, _sinks) when is_list(sizes) do
    sorted = sizes |> Enum.uniq() |> Enum.sort_by(&area/1, :desc)

    case Map.get(request, :size) || encoder.size do
      nil ->
        sorted

      wanted ->
        case Enum.filter(sorted, &(area(&1) <= area(wanted))) do
          [] -> [List.last(sorted)]
          fitting -> fitting
        end
    end
  end

  # A relay that doesn't list its sizes sends the one it has.
  defp sizes(%Format{element: :relay} = encoder, _request, _sinks), do: [encoder.size]

  defp sizes(encoder, request, sinks) do
    case Map.get(request, :size) || encoder.size || encoder.max_size do
      nil ->
        [nil]

      wanted ->
        {w, h} = wanted = fit_within(wanted, encoder.max_size)

        fitted =
          for {_ref, candidates, _pref} <- sinks,
              %Format{max_size: max} <- candidates,
              max != nil,
              do: fit_within(wanted, max)

        steps = for step <- @ladder, step < h, do: {even(div(w * step, h)), step}

        [wanted | fitted ++ steps]
        |> Enum.uniq()
        |> Enum.filter(&(area(&1) <= area(wanted)))
        |> Enum.sort_by(&area/1, :desc)
    end
  end

  defp fit_within(size, nil), do: size
  defp fit_within({w, h}, {max_w, max_h}) when w <= max_w and h <= max_h, do: {w, h}

  defp fit_within({w, h}, {max_w, max_h}) do
    scale = min(max_w / w, max_h / h)
    {even(trunc(w * scale)), even(trunc(h * scale))}
  end

  defp even(n), do: max(2, n - rem(n, 2))
  defp area({w, h}), do: w * h

  defp min_of(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      values -> Enum.min(values)
    end
  end

  ## Tools

  @doc """
  The video support of the cluster's cameras and displays (`filters` as for
  `Home.Registry.list/1`): `%{ref, device_id, kind, encode: [...]}` for a `:video_in`,
  `decode: [...]` for a `:display`. A node running a home_base from before video support
  has neither.
  """
  @spec list(keyword()) :: [map()]
  def list(filters \\ []) do
    for info <- Home.Registry.list(Keyword.put_new(filters, :kind, [:video_in, :display])) do
      Map.merge(
        %{ref: info.ref, device_id: info.device_id, kind: info.cap.kind},
        Map.get(info, :video) || %{}
      )
    end
  end

  @doc """
  Negotiate a stream from the capability `source` to the capabilities `sinks` the way a
  session would, from their registry info, leasing nothing. `opts`: `:size`, `:fps`,
  `:bitrate`, `:decoder`.
  """
  @spec check(Home.Capability.ref(), [Home.Capability.ref()], keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def check(source, sinks, opts \\ []) do
    preference = Keyword.get(opts, :decoder, :auto)

    with {:ok, source_info} <- info(source),
         {:ok, sink_infos} <- infos(List.wrap(sinks)) do
      sinks = for info <- sink_infos, do: {info.ref, formats(info, :decode), preference}
      negotiate(formats(source_info, :encode), sinks, Keyword.take(opts, [:size, :fps, :bitrate]))
    end
  end

  defp info(ref) do
    with {:ok, pid} <- Home.Registry.whereis(ref) do
      {:ok, Home.Capability.Server.info(pid)}
    end
  catch
    :exit, reason -> {:error, {:unreachable, ref, reason}}
  end

  defp infos(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case info(ref) do
        {:ok, info} -> {:cont, {:ok, acc ++ [info]}}
        {:error, :not_found} -> {:halt, {:error, {:not_found, ref}}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "A path or format in a line, for logs and screens."
  @spec describe(Path.t() | Format.t()) :: String.t()
  def describe(%Path{} = path) do
    stream =
      [
        "H.264",
        path.profile && profile_name(path.profile),
        path.size && size_name(path.size),
        path.fps && "#{path.fps} fps",
        path.level && "level #{level_name(path.level)}",
        path.bitrate && rate_name(path.bitrate)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    decoders = path.decoders |> Map.values() |> Enum.map(&kind_label/1) |> Enum.uniq()
    "#{stream}, #{kind_label(path.encoder)} to #{Enum.join(decoders, ", ")}"
  end

  def describe(%Format{} = format) do
    limits =
      [
        format.profiles && Enum.map_join(format.profiles, "/", &profile_name/1),
        format.sizes && Enum.map_join(format.sizes, ", ", &size_name/1),
        format.max_size && "up to #{size_name(format.max_size)}",
        format.max_fps && "#{format.max_fps} fps",
        format.max_level && "level #{level_name(format.max_level)}",
        format.max_bitrate && "up to #{rate_name(format.max_bitrate)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "#{kind_label(format)}: H.264 #{limits}" |> String.trim_trailing()
  end

  @doc "`{:no_video_path, reasons}`, or the reasons, in words: a line each."
  @spec explain({:no_video_path, [failure()]} | [failure()]) :: [String.t()]
  def explain({:no_video_path, reasons}), do: explain(reasons)
  def explain(reasons) when is_list(reasons), do: Enum.map(reasons, &reason/1)

  defp reason(%{sink: sink, decoder: decoder, reason: reason}) do
    who = Enum.reject([sink && inspect(sink), decoder], &is_nil/1) |> Enum.join(" ")
    "#{who}: #{reason(reason)}" |> String.trim_leading(": ")
  end

  defp reason(:no_encoder), do: "the source has no video encoder"
  defp reason({:no_decoder, :software}), do: "no software decoder"
  defp reason({:no_decoder, :hardware}), do: "no hardware decoder"
  defp reason({:no_decoder, _}), do: "no decoder for H.264"
  defp reason({:codec, codec}), do: "doesn't decode #{codec}"

  defp reason({:profile, profile, profiles}),
    do:
      "doesn't take #{profile_name(profile)} (takes #{Enum.map_join(profiles, ", ", &profile_name/1)})"

  defp reason({:size, size, max}),
    do: "takes up to #{size_name(max)}, the stream is #{size_name(size)}"

  defp reason({:fps, fps, max}), do: "takes up to #{max} fps, the stream is #{fps}"

  defp reason({:bitrate, bitrate, max}),
    do: "takes up to #{rate_name(max)}, the stream is #{rate_name(bitrate)}"

  defp reason({:level, level, max}),
    do: "goes up to level #{level_name(max)}, the stream needs #{level_name(level)}"

  defp reason(other), do: inspect(other)

  defp kind_label(%Format{} = format),
    do: "#{label(format)} (#{if format.hardware, do: "hardware", else: "software"})"

  defp label(%Format{name: name}) when is_binary(name), do: name
  defp label(%Format{element: element}), do: element_name(element)

  defp element_name({module, _opts}), do: element_name(module)
  defp element_name(module) when is_atom(module), do: inspect(module)

  defp profile_name(:constrained_baseline), do: "constrained baseline"
  defp profile_name(profile), do: to_string(profile)

  defp size_name({w, h}), do: "#{w}×#{h}"
  defp level_name(level), do: "#{div(level, 10)}.#{rem(level, 10)}"

  defp rate_name(bps) when bps < 1_000_000, do: "#{div(bps, 1_000)} kbit/s"
  defp rate_name(bps), do: "#{Float.round(bps / 1_000_000, 1)} Mbit/s"
end
