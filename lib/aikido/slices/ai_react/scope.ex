defmodule Aikido.Slices.AiReact.Scope do
  @moduledoc "Pure caller scope validation and binding for ReAct runs."

  @doc false
  def validate(state, input) do
    if state.status in [:setup, :running, :waiting] &&
         Map.merge(%{actor: nil, tenant: nil}, Map.get(state, :run_scope, %{})) != caller(input),
       do: {:error, :scope_mismatch},
       else: :ok
  end

  @doc false
  def bind({:ok, result}, input),
    do: {:ok, %{result | state: Map.put(result.state, :run_scope, caller(input))}}

  def bind(error, _input), do: error

  defp caller(input),
    do: Map.merge(%{actor: nil, tenant: nil}, Map.take(input.context.aikido, [:actor, :tenant]))
end
