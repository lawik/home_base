defmodule Home.Cluster.Static do
  @moduledoc "A fixed peer list: `{Home.Cluster.Static, nodes: [:\"home@10.0.0.2\"]}`."
  @behaviour Home.Cluster

  @impl true
  def peers(opts), do: {:ok, Keyword.get(opts, :nodes, [])}
end
