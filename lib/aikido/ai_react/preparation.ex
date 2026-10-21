defmodule Aikido.AiReact.Preparation do
  @moduledoc "Pure tool preparation and handoff planning shared by ReAct actions."

  alias Aikido.AiReact.Directives.{LLMCall, PrepareTools, ToolExec}

  @doc false
  def finish({:ok, %{state: state, directives: []}} = unchanged, input)
      when state == input.arguments.state,
      do: unchanged

  def finish(result, _input) do
    result |> prepare_tools() |> Aikido.AiReact.Handoff.plan()
  end

  defp prepare_tools({:ok, result}) do
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

  defp prepare_tools(error), do: error
end
