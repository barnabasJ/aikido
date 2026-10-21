defmodule Aikido.AiReact.Scope do
  @moduledoc "Pure caller scope validation and binding for ReAct runs."

  @doc "Require incoming actor and tenant to match an active run’s caller."
  def validate_run_caller(state, input) do
    if state.status in [:setup, :running, :waiting] &&
         Map.merge(%{actor: nil, tenant: nil}, Map.get(state, :run_scope, %{})) !=
           actor_and_tenant(input),
       do: {:error, :scope_mismatch},
       else: :ok
  end

  @doc "Record the opening caller’s actor and tenant on the run state."
  def bind_run_caller({:ok, result}, input),
    do: {:ok, %{result | state: Map.put(result.state, :run_scope, actor_and_tenant(input))}}

  def bind_run_caller(error, _input), do: error

  defp actor_and_tenant(input),
    do: Map.merge(%{actor: nil, tenant: nil}, Map.take(input.context.aikido, [:actor, :tenant]))
end
