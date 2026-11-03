defmodule Aikido.AiReact.RunCaller do
  @moduledoc """
  Binds each ReAct run to its opening actor and tenant.

  Incoming messages must match that caller while the run is active. This is a
  run-ownership check; native Ash scope still carries authorization and context.
  """

  @doc "Require incoming actor and tenant to match an active run’s caller."
  def validate_run_caller(state, input) do
    with :ok <- validate_execution_identity(input) do
      if state.status in [:setup, :running, :waiting] &&
           Map.merge(%{actor: nil, tenant: nil}, Map.get(state, :run_scope, %{})) !=
             actor_and_tenant(input),
         do: {:error, :scope_mismatch},
         else: :ok
    end
  end

  @doc "Record the opening caller’s actor and tenant on the run state."
  def bind_run_caller({:ok, state, directives}, input) do
    with :ok <- validate_execution_identity(input) do
      {:ok, Map.put(state, :run_scope, actor_and_tenant(input)), directives}
    end
  end

  def bind_run_caller(error, _input), do: error

  defp validate_execution_identity(input) do
    case input.context.aikido[:execution_scope] do
      nil ->
        :ok

      scope ->
        if Aikido.Agent.ExecutionIdentity.matches?(scope, input.context.aikido),
          do: :ok,
          else: {:error, Aikido.Agent.Errors.ExecutionIdentityRequiresRestart.exception([])}
    end
  end

  defp actor_and_tenant(input),
    do: Map.merge(%{actor: nil, tenant: nil}, Map.take(input.context.aikido, [:actor, :tenant]))
end
