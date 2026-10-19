defmodule Home.Indicator.App do
  @moduledoc """
  The Solve app behind `Home.Indicator`: one `:leases` controller
  (`Home.Indicator.Leases`). App params (`node:`) are its params.

      {:ok, app} = Home.Indicator.App.start_link(params: %{})
      Solve.subscribe(app, :leases)
      #=> %{node: :"kitchen@...", in_use: [...], idle: 3}
      Solve.dispatch(app, :leases, :revoke_all, nil)
  """

  use Solve

  @impl Solve
  def controllers do
    [
      controller!(
        name: :leases,
        module: Home.Indicator.Leases,
        params: fn %{app_params: params} -> params || %{} end
      )
    ]
  end
end
