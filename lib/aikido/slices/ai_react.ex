defmodule Aikido.Slices.AiReact do
  @moduledoc """
  ReAct strategy as a configured `Aikido.Slice`.

  Attached to any `Aikido.Agent` via the agent's `extensions:` list and
  configured through the contributed `react do … end` section:

      defmodule MyApp.SupportAgent do
        use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

        agent do
          name "support"
        end

        react do
          model "anthropic:claude-haiku-4-5-20251001"
          tools [MyApp.Actions.LookupOrder, MyApp.Actions.RefundOrder]
          system_prompt "You are a support agent."
          max_iterations 5
        end

        slices do
          slice :ai, Aikido.Slices.AiReact
        end
      end

  The slice owns the `:ai` key of the agent's state and contains the full
  lifecycle of one ReAct conversation.

  ## State machine

      :idle ──ask──▶ :running ─┬─final answer──▶ :completed
                               ├─tool calls + iter < max ─▶ :running (next iter)
                               ├─tool calls + iter ≥ max ─▶ :completed (truncated)
                               └─LLM error ──▶ :failed

  Concurrent `ai.react.ask` while `:running` is rejected with
  `{:error, :busy}` (ADR 0022 §5).

  ## Slice fields

    * `:status` — `:idle | :running | :completed | :failed`.
    * `:request_id` — opaque correlation id minted by `Aikido.AI.ask/3`.
      Every response signal carries it; mismatched signals are dropped as
      stale.
    * `:context` — the full `ReqLLM.Context` carried verbatim per ADR
      0022 §3 — system + user + assistant + tool messages.
    * `:iteration` — number of LLM calls completed so far.
    * `:max_iterations` — cap on LLM calls; further `:tool_calls` turns
      after this is reached truncate the run as `:completed`.
    * `:result` — final answer text on `:completed`, or `nil`.
    * `:error` — error term on `:failed`, or `nil`.
    * `:pending_tool_calls` — tool calls from the last `:tool_calls` turn,
      kept until every paired tool result has come back.
    * `:tool_results_received` — tool results accumulated for the in-flight
      tool batch; cleared when the batch completes and the next LLMCall
      fires.
    * `:previous_tool_signature` — signature of the last batch's tool
      calls; used to detect tool-call cycles and prepend a cycle-warning
      user message before the next LLMCall.
    * `:model`, `:tools`, `:system_prompt`, `:llm_opts` — run config
      seeded from the slice's `slices:` config (validated through
      `config_schema/0`); `Aikido.Slices.AiReact.Actions.Ask` falls back to these
      values when the opening signal omits them.

  ## Config keys (`config_schema/0`)

    * `:model` — any value accepted by `ReqLLM.Generation.generate_text/3`.
      Optional; the floor enforced by the `Ask` action is `{:error, :no_model}`
      when neither the slice config nor the per-call `Aikido.AI.ask/3` opts
      supply a model.
    * `:tools` — runtime tool objects, contextual callback pairs, Ash action references, or Aikido actions exposed to the model.
    * `:system_prompt` — system message text prepended to the conversation.
    * `:max_iterations` — cap on LLM calls per run (default 10).
    * `:max_tokens` — folded into `:llm_opts` (default 4096).
    * `:temperature` — folded into `:llm_opts` (default 0.2).
    * `:llm_opts` — extra keyword list merged into per-call options
      (last-write-wins over `:max_tokens` / `:temperature`).
  """

  alias Aikido.Slices.AiReact.Actions

  @cycle_warning "You already called the same tool(s) with identical parameters in the previous iteration and got the same results. Do NOT repeat the same calls. Either use the results you already have to form a final answer, or try a different approach."

  use Aikido.Slice

  slice do
    name "ai"
    description "ReAct reasoning slice attached via `slices:` on a Aikido.Agent."

    schema do
      attribute :status, :atom, allow_nil?: false, default: :idle
      attribute :request_id, :term, allow_nil?: true, default: nil
      attribute :context, :term, allow_nil?: true, default: nil
      attribute :iteration, :integer, allow_nil?: false, default: 0
      attribute :max_iterations, :integer, allow_nil?: false, default: 10
      attribute :result, :term, allow_nil?: true, default: nil
      attribute :error, :term, allow_nil?: true, default: nil
      attribute :pending_tool_calls, {:array, :term}, allow_nil?: false, default: []
      attribute :tool_results_received, {:array, :term}, allow_nil?: false, default: []
      attribute :previous_tool_signature, :term, allow_nil?: true, default: nil
      attribute :model, :term, allow_nil?: true, default: nil
      attribute :client, :atom, allow_nil?: false, default: ReqLLM.Generation
      attribute :tools, {:array, :term}, allow_nil?: false, default: []
      attribute :tool_context, :map, allow_nil?: false, default: %{}
      attribute :system_prompt, :term, allow_nil?: true, default: nil
      attribute :llm_opts, :term, allow_nil?: false, default: []
    end

    config_schema do
      attribute :model, :term, allow_nil?: true
      attribute :client, :atom, allow_nil?: false, default: ReqLLM.Generation
      attribute :tools, {:array, :term}, allow_nil?: false, default: []
      attribute :tool_context, :map, allow_nil?: false, default: %{}
      attribute :system_prompt, :term, allow_nil?: true
      attribute :max_iterations, :integer, allow_nil?: false, default: 10
      attribute :max_tokens, :integer, allow_nil?: false, default: 4096
      attribute :temperature, :term, allow_nil?: false, default: 0.2
      attribute :llm_opts, :term, allow_nil?: false, default: []
    end

    config_transform {__MODULE__, :__fold_llm_opts__, []}
  end

  signal_routes do
    route "ai.react.ask", Actions.Ask
    route "ai.react.llm.completed", Actions.LLMTurn
    route "ai.react.tool.completed", Actions.ToolResult
    route "ai.react.failed", Actions.Failed
    route "ai.react.cancel", Actions.Cancel
  end

  @react_section %Spark.Dsl.Section{
    name: :react,
    describe: "ReAct reasoning slice attached via `slices:` on a Aikido.Agent.",
    schema: [
      model: [type: :any, doc: "Model spec accepted by `ReqLLM.Generation.generate_text/3`."],
      client: [
        type: :module,
        default: ReqLLM.Generation,
        doc: "Module implementing the model-call boundary."
      ],
      tool_context: [type: :map, default: %{}],
      tools: [
        type: {:list, :any},
        default: [],
        doc: "Aikido.Action modules or {AshResource, generic_action} tool references."
      ],
      system_prompt: [type: :any, doc: "System message text prepended to the conversation."],
      max_iterations: [type: :integer, default: 10, doc: "Cap on LLM calls per run."],
      max_tokens: [
        type: :integer,
        default: 4096,
        doc: "Default max tokens, folded into `:llm_opts`."
      ],
      temperature: [
        type: :any,
        default: 0.2,
        doc: "Default temperature, folded into `:llm_opts`."
      ],
      llm_opts: [
        type: :any,
        default: [],
        doc:
          "Extra keyword list merged into per-call options " <>
            "(last-write-wins over `:max_tokens` / `:temperature`)."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@react_section],
    transformers: [Aikido.Slices.AiReact.Transformers.RegisterContribution]

  @doc false
  # Folds the convenience keys `:max_tokens` and `:temperature` into
  # `:llm_opts` so the slice carries a single keyword list of per-call
  # options. The state schema doesn't track them as separate fields; this
  # The config transform runs after Ash casting and before the
  # config is merged into slice state.
  @spec __fold_llm_opts__(map(), term()) :: {:ok, map()}
  def __fold_llm_opts__(config, _ctx) when is_map(config) do
    {max_tokens, config} = Map.pop(config, :max_tokens)
    {temperature, config} = Map.pop(config, :temperature)
    base_opts = config[:llm_opts] || []

    llm_opts =
      base_opts
      |> put_unless_present(:max_tokens, max_tokens)
      |> put_unless_present(:temperature, temperature)

    {:ok, Map.put(config, :llm_opts, llm_opts)}
  end

  defp put_unless_present(opts, _key, nil) do
    opts
  end

  defp put_unless_present(opts, key, value) do
    if Keyword.has_key?(opts, key) do
      opts
    else
      Keyword.put(opts, key, value)
    end
  end

  @doc """
  The cycle-warning user message appended to the context when the next
  LLMCall would otherwise repeat the previous tool-call batch verbatim.
  """
  @spec cycle_warning() :: String.t()
  def cycle_warning do
    @cycle_warning
  end

  @doc """
  Tool-call signature for cycle detection.

  Stable, sortable, and tolerant of mixed atom/string keys (different
  ReqLLM provider adapters return one or the other).
  """
  @spec tool_call_signature([map()]) :: String.t()
  def tool_call_signature(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(fn tc ->
      name = Map.get(tc, :name) || Map.get(tc, "name") || ""
      args = Map.get(tc, :arguments) || Map.get(tc, "arguments") || ""
      "#{name}:#{inspect(args)}"
    end)
    |> Enum.sort()
    |> Enum.join("|")
  end
end
