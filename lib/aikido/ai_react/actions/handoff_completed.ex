defmodule Aikido.AiReact.Actions.HandoffCompleted do
  @moduledoc "Adopts a validated handoff document, retains usage and resumes the next model turn."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Handoff, Hooks}
  alias Aikido.AiReact.Directives.LLMCall
  alias Aikido.AiReact.Context

  @impl true
  def run(input, _opts, _context) do
    input.arguments.state
    |> reduce(Map.delete(input.arguments, :state))
  end

  @doc false
  def reduce(state, data) do
    if Handoff.active?(state, data) do
      response = data.turn
      turn = ReqLLM.Response.classify(response)

      cond do
        turn.type != :final_answer || String.trim(turn.text) == "" ->
          Aikido.AiReact.Actions.HandoffFailed.reduce(
            state,
            Map.put(data, :reason, :empty_or_invalid_document)
          )

        turn.finish_reason == :length ->
          Aikido.AiReact.Actions.HandoffFailed.reduce(
            state,
            Map.put(data, :reason, :truncated_document)
          )

        true ->
          document = String.trim(turn.text)
          system = Enum.filter(state.context.messages, &(&1.role == :system))
          context = ReqLLM.Context.new(system)

          context =
            ReqLLM.Context.append(
              context,
              ReqLLM.Context.user("""
              You are taking over mid-run. Your predecessor left this handoff:

              #{document}

              Continue from the next action.\
              """)
            )

          context =
            Enum.reduce(state.queued_messages, context, fn text, context ->
              ReqLLM.Context.append(context, ReqLLM.Context.user(text))
            end)

          replacement = Context.replace_context(state, context)
          tokens = replacement.estimated_tokens
          options = state.options

          if tokens >= options.context_max_tokens do
            Aikido.AiReact.Actions.HandoffFailed.reduce(
              state,
              Map.put(data, :reason, :document_exceeds_context_limit)
            )
          else
            usage =
              Map.merge(state.usage, ReqLLM.Response.usage(response) || %{}, fn _, old, new ->
                if is_number(old) && is_number(new), do: old + new, else: new
              end)

            state =
              Map.merge(replacement, %{
                context: context,
                handoff_pending: nil,
                last_handoff: %{
                  document: document,
                  before_tokens: Handoff.current_tokens(state),
                  after_tokens: tokens,
                  id: data.handoff_id
                },
                last_input_tokens: nil,
                queued_messages: [],
                streaming_text: "",
                streaming_thinking: "",
                usage: usage
              })

            {tools, _registry} = state.prepared_tools

            effect = %LLMCall{
              mode: :resume,
              tools: tools,
              options: state.options,
              iteration: state.iteration + 1,
              model: state.model,
              client: state.client,
              context: context,
              request_id: state.request_id,
              llm_opts: state.llm_opts
            }

            Hooks.transition(
              Aikido.Types.ActionResult.new(state: state, directives: [effect]),
              :after_model,
              %{handoff: true}
            )
          end
      end
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
