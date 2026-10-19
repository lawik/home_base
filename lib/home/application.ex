defmodule Home.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Home.start_link(Application.get_all_env(:home_base))
  end
end
