defmodule Home.Cluster.Tailscale do
  @moduledoc """
  Peers are the online tailnet devices tagged `tag:homecluster`, named
  `<basename>@<first Tailscale IP>`. Reads `tailscale status --json`.

  Options: `:tag` (default `"tag:homecluster"`), `:basename` (default `"home"`),
  `:cmd` (default `"tailscale"`).
  """
  @behaviour Home.Cluster

  @impl true
  def peers(opts) do
    cmd = Keyword.get(opts, :cmd, "tailscale")

    case System.cmd(cmd, ["status", "--json"], stderr_to_stdout: true) do
      {json, 0} -> {:ok, parse(Jason.decode!(json), opts)}
      {out, code} -> {:error, {:tailscale, code, out}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc "Node names from a decoded `tailscale status --json`."
  def parse(status, opts \\ []) do
    tag = Keyword.get(opts, :tag, "tag:homecluster")
    basename = Keyword.get(opts, :basename, "home")

    for {_key, peer} <- Map.get(status, "Peer") || %{},
        peer["Online"],
        tag in (peer["Tags"] || []),
        [ip | _] <- [ipv4_first(peer["TailscaleIPs"] || [])] do
      :"#{basename}@#{ip}"
    end
  end

  defp ipv4_first(ips), do: Enum.sort_by(ips, &String.contains?(&1, ":"))
end
