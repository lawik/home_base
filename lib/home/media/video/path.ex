defmodule Home.Media.Video.Path do
  @moduledoc """
  The video a session sends, as `Home.Media.Video.negotiate/3` settled it: one stream
  (`codec`, `profile`, `size`, `fps`, `level`, `bitrate`) that the source's `encoder`
  makes and each sink's decoder (`decoders`, by sink capability ref) takes.

  `nil` fields weren't known: an encoder that didn't say what it makes.
  """

  alias Home.Media.Video.Format

  @type t :: %__MODULE__{
          codec: :h264,
          profile: Format.profile() | nil,
          size: Format.size() | nil,
          fps: pos_integer() | nil,
          level: pos_integer() | nil,
          bitrate: pos_integer() | nil,
          encoder: Format.t(),
          decoders: %{Home.Capability.ref() => Format.t()}
        }

  defstruct codec: :h264,
            profile: nil,
            size: nil,
            fps: nil,
            level: nil,
            bitrate: nil,
            encoder: nil,
            decoders: %{}
end
