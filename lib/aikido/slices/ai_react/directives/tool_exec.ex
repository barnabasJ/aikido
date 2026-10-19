defmodule Aikido.Slices.AiReact.Directives.ToolExec do
  @moduledoc """
  Side-effect directive: runs one tool call.

  Emitted by the ReAct action, one per requested tool call. The executor
  spawns a Task that rebuilds Ash AI's native registry from the configured
  tool selection, invokes its named callback, and casts an
  `"ai.react.tool.completed"` signal carrying Ash AI's serialized result.

  Native tool errors pass through as model content; runtime failures become
  error JSON inside the same `tool.completed` envelope. Tool failures are conversational
  data, not run failures, so the LLM can read the error and recover. A
  tool failure never produces an `"ai.react.failed"` signal.
  """

  use Aikido.Directive

  typed_struct do
    field :options, :term, default: %{}
    field :tool_call, :map, allow_nil?: false
    field :tools, {:array, :atom}, allow_nil?: false, default: []

    field :tool_options, Aikido.Types.Native,
      default: [otp_app: :aikido],
      constraints: [kind: :keyword_list]

    field :tool_context, :map, allow_nil?: false, default: %{}
    field :request_id, :string, allow_nil?: false
  end

  alias Aikido.AgentServer
  alias Jido.Signal
  alias Aikido.Slices.AiReact.Directives.ToolExec

  @impl true
  def exec(%ToolExec{} = directive, input_signal, state) do
    agent_pid = self()
    task_sup = Aikido.task_supervisor_name(state.aikido)
    source = "/agent/#{state.id}"
    agent_module = Map.get(state, :agent_module)

    inherited =
      if match?(%Jido.Signal{}, input_signal), do: Aikido.SignalCtx.ctx(input_signal), else: %{}

    context =
      Map.merge(Map.merge(directive.tool_context, inherited), %{
        agent_id: state.id,
        request_id: directive.request_id,
        tool_call_id: directive.tool_call.id,
        agent_resource:
          if(function_exported?(agent_module, :__aikido_resource__, 0),
            do: agent_module.__aikido_resource__()
          ),
        aikido: state.aikido,
        partition: Map.get(state, :partition),
        parent: Map.get(state, :parent)
      })

    context =
      Map.put(
        context,
        :context,
        DeepMerge.deep_merge(directive.tool_context[:context] || %{}, inherited[:context] || %{})
      )

    {:ok, _pid} =
      Task.Supervisor.start_child(task_sup, fn ->
        run_and_dispatch(directive, agent_pid, source, context, task_sup)
      end)

    :ok
  end

  defp run_and_dispatch(%ToolExec{} = d, agent_pid, source, context, supervisor) do
    options = Aikido.AI.Options.resolve(d.options)

    result =
      Aikido.AI.Execution.run(
        agent_pid,
        d.request_id,
        supervisor,
        fn _notify, _attempt -> run_tool(d.tool_call, d.tools, d.tool_options, context) end,
        timeout: options.tool_timeout_ms,
        retries: options.tool_max_retries,
        backoff: options.retry_backoff_ms
      )

    content =
      case result do
        {:ok, content} -> content
        {:error, reason} -> Jason.encode!(%{error: format_error(reason)})
      end

    data = %{
      tool_call_id: d.tool_call.id,
      name: d.tool_call.name,
      content: content,
      request_id: d.request_id
    }

    signal = Signal.new!("ai.react.tool.completed", data, source: source)

    _ =
      AgentServer.cast(
        agent_pid,
        Aikido.SignalCtx.put_ctx(
          signal,
          Map.new(Ash.Scope.to_opts(context))
        )
      )
  end

  defp run_tool(%{name: name, arguments: args}, tools, options, context) do
    ash_context =
      Map.put(Map.get(context, :context) || %{}, :aikido, Map.delete(context, :context))

    context = Map.put(context, :context, ash_context)

    {_, registry} =
      AshAi.build_tools_and_registry(
        options
        |> Keyword.merge(Ash.Scope.to_opts(context))
        |> Keyword.put(:tools, tools)
      )

    case Map.fetch(registry, name) do
      {:ok, callback} ->
        case callback.(args, context) do
          {:ok, content, _raw} -> {:ok, content}
          {:error, content} -> {:ok, content}
        end

      :error ->
        {:error, "tool not found: #{name}"}
    end
  end

  defp format_error(%{errors: errors}) when is_list(errors),
    do: Enum.map_join(errors, "; ", &format_error/1)

  defp format_error(%Ash.Error.Unknown.UnknownError{error: error}), do: format_error(error)
  defp format_error(%_{} = err) when is_exception(err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
