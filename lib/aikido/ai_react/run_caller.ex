defmodule Aikido.AiReact.RunCaller do
  @moduledoc """
  Binds each ReAct run to its opening actor and tenant.

  Incoming messages must match that caller while the run is active. This is a
  run-ownership check; native Ash scope still carries authorization and context.
  """

  @doc "Require incoming actor and tenant to match an active run’s caller."
  def validate_run_caller(state, input) do
    if state.status in [:setup, :running, :waiting] &&
         Map.merge(%{actor: nil, tenant: nil}, Map.get(state, :run_scope, %{})) !=
           actor_and_tenant(input),
       do: {:error, :scope_mismatch},
       else: :ok
  end

  @doc "Record the opening caller’s actor and tenant on the run state."
  def bind_run_caller({:ok, state, directives}, input),
    do: {:ok, Map.put(state, :run_scope, actor_and_tenant(input)), directives}

  def bind_run_caller(error, _input), do: error

  defp actor_and_tenant(input),
    do: Map.merge(%{actor: nil, tenant: nil}, Map.take(input.context.aikido, [:actor, :tenant]))
end
