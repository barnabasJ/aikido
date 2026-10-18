defmodule Aikido.Slices.AiReact.Actions.Ask do
  @moduledoc """
  Handles `"ai.react.ask"` — opens a ReAct run.

  Refuses concurrent runs (`{:error, :busy}` when `slice.status == :running`,
  per ADR 0022 §5), otherwise seeds the slice with a fresh
  `ReqLLM.Context`, transitions to `:running`, stores the run config
  (model / tools / system_prompt / llm_opts) so subsequent `LLMCall`
  directives in the same run can reuse it, and emits the first
  `Aikido.Slices.AiReact.Directives.LLMCall` to start the conversation.

  Per-call signal data fields override the slice's seeded config; when a
  field is omitted from the signal the action falls back to the slice's
  stored value. With no model in either place the action returns
  `{:error, :no_model}`.

  ADR 0019: this action only mutates state and emits a directive — the
  blocking ReqLLM call lives in the directive's executor.
  """

  use Aikido.Action

  action do
    name "ai_ask"
    description "Open a ReAct run on a Aikido.Slices.AiReact-equipped agent."

    schema do
      attribute :query, :string, allow_nil?: false
      attribute :request_id, :string, allow_nil?: false
      attribute :model, :term
      attribute :client, :atom
      attribute :tools, {:array, :term}
      attribute :system_prompt, :string
      attribute :max_iterations, :integer, constraints: [min: 1]
      attribute :llm_opts, Aikido.Types.Native, constraints: [kind: :keyword_list]
    end
  end

  alias Aikido.Slices.AiReact.Directives.LLMCall
  alias ReqLLM.Context

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    if running?(slice) do
      {:error, :busy}
    else
      open_run(data, slice)
    end
  end

  defp open_run(data, slice) do
    model = data[:model] || slice_field(slice, :model)

    tools =
      if is_nil(data[:tools]) do
        slice_field(slice, :tools) || []
      else
        data[:tools]
      end

    system_prompt = data[:system_prompt] || slice_field(slice, :system_prompt)
    max_iter = data[:max_iterations] || slice_field(slice, :max_iterations) || 10
    llm_opts = Keyword.merge(slice_field(slice, :llm_opts) || [], data[:llm_opts] || [])
    client = Map.get(data, :client) || slice_field(slice, :client) || ReqLLM.Generation

    if is_nil(model) do
      {:error, :no_model}
    else
      build_run(
        data,
        system_prompt,
        model,
        tools,
        max_iter,
        llm_opts,
        client,
        slice_field(slice, :tool_context) || %{}
      )
    end
  end

  defp build_run(data, system_prompt, model, tools, max_iter, llm_opts, client, tool_context) do
    context = build_initial_context(data.query, system_prompt)

    new_slice = %{
      status: :running,
      request_id: data.request_id,
      context: context,
      iteration: 0,
      max_iterations: max_iter,
      result: nil,
      error: nil,
      pending_tool_calls: [],
      tool_results_received: [],
      previous_tool_signature: nil,
      model: model,
      client: client,
      tools: tools,
      tool_context: tool_context,
      system_prompt: system_prompt,
      llm_opts: llm_opts
    }

    directive = %LLMCall{
      client: client,
      model: model,
      context: context,
      tools: tools,
      request_id: data.request_id,
      llm_opts: llm_opts
    }

    {:ok, new_slice, [directive]}
  end

  defp running?(%{status: :running}) do
    true
  end

  defp running?(_) do
    false
  end

  defp slice_field(nil, _key) do
    nil
  end

  defp slice_field(slice, key) when is_map(slice) do
    Map.get(slice, key)
  end

  defp build_initial_context(query, nil) do
    Context.new([Context.user(query)])
  end

  defp build_initial_context(query, system) when is_binary(system) do
    Context.new([Context.system(system), Context.user(query)])
  end
end
