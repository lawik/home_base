defmodule Home.Media.Video.Format do
  @moduledoc """
  One way a node can make or take video: an encoder a `:video_in` capability sends with,
  or a decoder a `:display`'s node shows with (see `Home.Media.Video`).

    * `:codec` - `:h264`.
    * `:hardware` - whether it runs on dedicated hardware rather than the CPU.
    * `:element` - what runs it: for a decoder, `:software` (FFmpeg, then RGB) or a
      Membrane filter (`module` or `{module, opts}`) from Annex B access units to
      `%VideoInterop.Frame{}`s or RGB/RGBA; for an encoder, `:software` (x264 on the
      source's node) or `:relay` (the capability sends H.264 it gets already encoded,
      through a `Home.Media.H264Relay`).
    * `:name` - a label for people, e.g. `"Venus"`.
    * `:profiles` - H.264 profiles it makes (an encoder, in order of preference) or takes
      (a decoder): `:constrained_baseline`, `:baseline`, `:main`, `:high`. `nil` if
      unknown, which matches anything.
    * `:max_level` - highest H.264 level, as `level_idc` (31 for 3.1, 51 for 5.1).
    * `:max_size` - largest `{width, height}`. For a decoder that wants small pictures
      (a watch), this is what has them made small at the source: the stream is no
      larger.
    * `:sizes` - an encoder that only makes certain sizes: the list of them.
    * `:max_fps`.
    * `:max_bitrate` (bits per second) - what an encoder can send, or the most a decoder
      wants to receive: a stream is settled at no more than any of its sinks' (a sink
      joining a running stream above it is refused).
    * `:size`, `:fps`, `:bitrate` - an encoder's defaults, used unless a session asks for
      something else.

  `nil` limits are no limit. Formats are plain data: they go into the registry's
  capability info (`video:`), where every node can read them.
  """

  @type profile :: :constrained_baseline | :baseline | :main | :high
  @type size :: {pos_integer(), pos_integer()}

  @type t :: %__MODULE__{
          codec: :h264,
          hardware: boolean(),
          element: :software | :relay | module() | {module(), keyword()},
          name: String.t() | nil,
          profiles: [profile()] | nil,
          max_level: pos_integer() | nil,
          max_size: size() | nil,
          sizes: [size()] | nil,
          max_fps: pos_integer() | nil,
          max_bitrate: pos_integer() | nil,
          size: size() | nil,
          fps: pos_integer() | nil,
          bitrate: pos_integer() | nil
        }

  defstruct codec: :h264,
            hardware: false,
            element: :software,
            name: nil,
            profiles: nil,
            max_level: nil,
            max_size: nil,
            sizes: nil,
            max_fps: nil,
            max_bitrate: nil,
            size: nil,
            fps: nil,
            bitrate: nil

  @doc "A format from a struct, map or keyword list of its fields."
  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = format), do: format
  def new(fields) when is_map(fields) or is_list(fields), do: struct!(__MODULE__, fields)
end
