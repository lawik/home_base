defmodule Home.Cluster.Epmd do
  @moduledoc """
  Peers are the other BEAMs registered in the local epmd whose names start with
  `:prefix` (default: this node's own name prefix up to the first `-` or digit). For
  running several nodes on one machine during development.
  """
  @behaviour Home.Cluster

  @impl true
  def peers(opts) do
    [name, host] = node() |> Atom.to_string() |> String.split("@", parts: 2)
    prefix = Keyword.get_lazy(opts, :prefix, fn -> default_prefix(name) end)

    case :erl_epmd.names(String.to_charlist(host)) do
      {:ok, names} ->
        {:ok,
         for({n, _port} <- names, String.starts_with?(to_string(n), prefix), do: :"#{n}@#{host}")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_prefix(name), do: name |> String.split(~r/[-_0-9]/, parts: 2) |> hd()
end
