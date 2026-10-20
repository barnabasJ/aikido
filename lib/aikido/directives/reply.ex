defmodule Aikido.Directives.Reply do
  @moduledoc """
  Directive that builds a reply signal from the full `%AgentServer.State{}`
  at execution time and dispatches it to the caller of a
  `Aikido.Signal.Call.call/3` request.

  ## Why this is a directive, not an action

  Actions run with a sandboxed context (`agent.state`, the agent struct,
  the input signal) — they deliberately do not see server-level
  internals like `state.children` or `state.aikido`.
  That's the right shape for domain logic, but it's the wrong shape for
  introspection queries that *must* read server state to answer
  correctly (e.g. "which of my nodes is running right now?").

  Directive executors receive the full `%AgentServer.State{}` as a
  documented part of the `Aikido.Directive` behaviour. So we push query
  resolution through a directive: the action's job is only to translate
  "a query signal came in" into "emit a Reply directive"; the
  directive's executor then reads whatever state it needs and produces
  the reply.

  ## Fields

  * `input_signal` — the query signal (carries `id` for correlation and
    `jido_dispatch` for the reply channel).
  * `reply_type` — signal type for a successful reply.
  * `error_type` — signal type when `build` returns `{:error, _}`.
  * `build` — `{module, fun, extra_args}`. Runtime calls
    `apply(module, fun, [%AgentServer.State{} | extra_args])` and
    expects `{:ok, map}` or `{:error, term}`.

  ## Example

      %Reply{
        input_signal: sig,
        reply_type: "aikido.agent.query.children.reply",
        error_type: "aikido.agent.query.children.error",
        build: {Aikido.AgentServer.Actions.QueryChildren, :build_reply, []}
      }

  `Aikido.Signal.Call.reply_from_state/4` is the recommended builder.
  """

  use Aikido.Directive

  typed_struct do
    field :input_signal, :term, allow_nil?: false
    field :reply_type, :string, allow_nil?: false
    field :error_type, :string, allow_nil?: false
    field :build, :term, allow_nil?: false
  end

  @type builder ::
          {module :: module(), fun :: atom(), extra_args :: [term()]}

  alias Jido.Signal

  require Logger

  @impl true
  def exec(%{input_signal: nil}, _input_signal, _state), do: :ok

  def exec(%{input_signal: %{jido_dispatch: nil}}, _input_signal, _state) do
    # No reply channel on the input signal — caller wasn't using
    # Signal.Call.call/3, so there's no one to reply to.
    :ok
  end

  def exec(
        %Aikido.Directives.Reply{
          input_signal: input,
          reply_type: reply_type,
          error_type: error_type,
          build: {module, fun, extra_args}
        },
        _input_signal,
        state
      ) do
    {type, data} =
      case apply(module, fun, [state | extra_args]) do
        {:ok, data} when is_map(data) -> {reply_type, data}
        {:error, reason} -> {error_type, %{reason: reason}}
      end

    case Signal.new(type, data, subject: input.id) do
      {:ok, reply_signal} ->
        _ =
          Aikido.Directives.Emit.exec(
            %Aikido.Directives.Emit{signal: reply_signal, dispatch: input.jido_dispatch},
            input,
            state
          )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Reply directive: failed to build #{inspect(type)} reply signal: #{inspect(reason)}"
        )
    end

    :ok
  end
end
