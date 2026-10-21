defmodule Aikido.AiReact.DirectivePlan do
  @moduledoc """
  Prepares returned ReAct directives without executing them.

  Supplies model tool descriptions and execution registries when available.
  Otherwise queues model/tool work behind tool setup. Terminal states discard
  transient tool setup data; model requests may be replaced by a context handoff
  when the configured token threshold is reached.
  """

  alias Aikido.AiReact.Directives.{LLMCall, PrepareTools, ToolExec}

  @doc """
  Prepare tools for the action result, then plan a context handoff if needed.

  Unchanged state with no directives passes through without starting work.
  Errors also pass through unchanged. All returned effects remain descriptors
  for the runtime to execute after adopting the state.
  """
  def prepare_tools_and_handoff({:ok, %{state: state, directives: []}} = unchanged, input)
      when state == input.arguments.state,
      do: unchanged

  def prepare_tools_and_handoff(result, _input) do
    result |> prepare_tool_directives() |> Aikido.AiReact.Handoff.plan()
  end

  defp prepare_tool_directives({:ok, result}) do
    state = result.state

    cond do
      state.status not in [:setup, :running, :waiting] ->
        {:ok,
         %{
           result
           | state:
               Map.merge(state, %{
                 handoff_pending: nil,
                 prepared_tools: nil,
                 tool_preparation: []
               })
         }}

      prepared = Map.get(state, :prepared_tools) ->
        directives =
          Enum.map(result.directives, fn
            %LLMCall{mode: :handoff} = effect -> %{effect | tools: []}
            %LLMCall{} = effect -> %{effect | tools: elem(prepared, 0)}
            %ToolExec{} = effect -> %{effect | registry: elem(prepared, 1)}
            effect -> effect
          end)

        {:ok, %{result | directives: directives}}

      true ->
        {waiting, other} =
          Enum.split_with(
            result.directives,
            &match?(%{__struct__: module} when module in [LLMCall, ToolExec], &1)
          )

        pending = Map.get(state, :tool_preparation, []) ++ waiting
        state = Map.put(state, :tool_preparation, pending)

        if pending != [] && Map.get(result.state, :tool_preparation, []) == [] do
          effect = %PrepareTools{
            options: Map.get(state, :options, %{}),
            tools: state.tools,
            tool_options: state.tool_options,
            request_id: state.request_id
          }

          {:ok,
           %{
             result
             | state: state,
               directives: other ++ [effect]
           }}
        else
          {:ok, %{result | state: state, directives: other}}
        end
    end
  end

  defp prepare_tool_directives(error), do: error
end
