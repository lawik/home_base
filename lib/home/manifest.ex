defmodule Home.Manifest do
  @moduledoc """
  The static description of what a device has. Loaded from config at boot:

      config :home_base, :manifest,
        device_id: "nerves-kitchen-01",
        capabilities: [
          %{id: "spk0", kind: :audio_out, adapter: Home.Adapters.Audio.CaptureSpeaker}
        ]

  or `config :home_base, :manifest, {:file, path}` for a `.exs` file returning the same keyword.
  """

  defstruct [:device_id, :node, capabilities: []]

  @type t :: %__MODULE__{
          device_id: String.t(),
          node: node(),
          capabilities: [Home.Capability.t()]
        }

  def load do
    :home_base
    |> Application.get_env(:manifest, [])
    |> from_config()
  end

  def from_config({:file, path}) do
    {config, _} = Code.eval_file(path)
    from_config(config)
  end

  def from_config(config) do
    config = Map.new(config)

    %__MODULE__{
      device_id: Map.get(config, :device_id) || default_device_id(),
      node: node(),
      capabilities: Enum.map(Map.get(config, :capabilities, []), &capability/1)
    }
  end

  defp capability(%Home.Capability{} = cap), do: validate(cap)
  defp capability(attrs), do: validate(struct!(Home.Capability, attrs))

  defp validate(%Home.Capability{kind: kind} = cap) do
    unless kind in Home.Capability.kinds() do
      raise ArgumentError, "unknown capability kind #{inspect(kind)} for #{inspect(cap.id)}"
    end

    cap
  end

  defp default_device_id do
    {:ok, host} = :inet.gethostname()
    to_string(host)
  end
end
