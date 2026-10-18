defmodule Aikido.Slices.AiReact.Directives.ToolExec do
  @moduledoc """
  Side-effect directive: runs one tool call.

  Emitted by `Aikido.Slices.AiReact.Actions.LLMTurn`, one per tool call in a turn that
  asked for tools. The executor spawns a Task that resolves the tool by
  name, coerces arguments through the action's schema, runs the action
  via `Aikido.Exec.run/4`, and casts back an `"ai.react.tool.completed"`
  signal carrying a JSON-encoded result.

  Tool errors and crashes are caught and converted to error JSON inside
  the same `tool.completed` envelope — tool failures are conversational
  data, not run failures, so the LLM can read the error and recover. A
  tool failure never produces an `"ai.react.failed"` signal.
  """

  @type t :: %__MODULE__{
          tool_call: %{id: String.t(), name: String.t(), arguments: map()},
          tool_modules: [Aikido.Slices.AiReact.ToolAdapter.action()],
          tool_context: map(),
          request_id: String.t()
        }

  @enforce_keys [:tool_call, :request_id]
  defstruct tool_call: nil,
            tool_modules: [],
            tool_context: %{},
            request_id: nil
end

defimpl Aikido.AgentServer.DirectiveExec, for: Aikido.Slices.AiReact.Directives.ToolExec do
  @moduledoc false

  alias Aikido.Action.Tool, as: ActionTool
  alias Aikido.AgentServer
  alias Jido.Signal
  alias Aikido.Slices.AiReact.Directives.ToolExec
  alias Aikido.Slices.AiReact.ToolAdapter

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
        agent_resource:
          if(function_exported?(agent_module, :__aikido_resource__, 0),
            do: agent_module.__aikido_resource__()
          ),
        aikido: state.aikido,
        partition: Map.get(state, :partition),
        parent: Map.get(state, :parent)
      })

    {:ok, _pid} =
      Task.Supervisor.start_child(task_sup, fn ->
        run_and_dispatch(directive, agent_pid, source, context)
      end)

    :ok
  end

  defp run_and_dispatch(%ToolExec{} = d, agent_pid, source, context) do
    content = run_tool(d.tool_call, d.tool_modules, context)

    data = %{
      tool_call_id: d.tool_call.id,
      name: d.tool_call.name,
      content: content,
      request_id: d.request_id
    }

    signal = Signal.new!("ai.react.tool.completed", data, source: source)
    _ = AgentServer.cast(agent_pid, signal)
  end

  defp run_tool(%{name: name, arguments: args}, modules, context) do
    ash_context =
      Map.put(Map.get(context, :context) || %{}, :aikido, Map.delete(context, :context))

    context = Map.put(context, :context, ash_context)

    case ToolAdapter.lookup_action(name, modules) do
      {:ok, module} -> safe_invoke(module, args, name, context)
      {:error, :not_found} -> Jason.encode!(%{error: "tool not found: #{name}"})
    end
  end

  defp safe_invoke(tool, args, name, context) do
    case invoke(tool, args, context) do
      {:ok, result} -> encode_result(result)
      {:ok, result, _extra} -> encode_result(result)
      {:error, reason} -> Jason.encode!(%{error: format_error(reason)})
    end
  rescue
    exception ->
      Jason.encode!(%{error: "#{name} crashed: #{Exception.message(exception)}"})
  catch
    kind, reason ->
      Jason.encode!(%{error: "#{name} #{kind}: #{inspect(reason)}"})
  end

  defp encode_result(value) when is_binary(value), do: value
  defp encode_result(value), do: Jason.encode!(value)

  defp invoke({%ReqLLM.Tool{}, callback}, args, context) when is_function(callback, 2),
    do: callback.(args, context)

  defp invoke(%ReqLLM.Tool{} = tool, args, _context), do: ReqLLM.Tool.execute(tool, args)

  defp invoke({resource, action}, args, context) do
    AshAi.Tools.execute(
      ToolAdapter.ash_tool({resource, action}),
      args,
      context
    )
  end

  defp invoke(module, args, context) do
    params = ActionTool.convert_params_using_schema(args, Aikido.ActionRef.schema(module))
    Aikido.Exec.run(module, params, context, [])
  end

  defp format_error(%{errors: errors}) when is_list(errors),
    do: Enum.map_join(errors, "; ", &format_error/1)

  defp format_error(%Ash.Error.Unknown.UnknownError{error: error}), do: format_error(error)
  defp format_error(%_{} = err) when is_exception(err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
