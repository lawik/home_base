defmodule HomeNode.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Only configured for targets (config/target.exs): on a dev host this app does nothing.
    children =
      case Application.fetch_env(:home_node, :distribution) do
        {:ok, opts} -> [{HomeNode.Distribution, opts}]
        :error -> []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: HomeNode.Supervisor)
  end
end
