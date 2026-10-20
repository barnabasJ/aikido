defmodule Aikido.Slices.AiReact.Directives.ToolExec do
  @moduledoc """
  Side-effect directive: runs one tool call.

  Emitted by the ReAct action, one per requested tool call. The executor
  spawns a Task that invokes the named callback in the run's prepared
  Ash AI registry and casts an
  `"ai.react.tool.completed"` signal carrying Ash AI's native result.

  Native tool errors pass through as model content; runtime failures become
  error JSON inside the same `tool.completed` envelope. Tool failures are conversational
  data, not run failures, so the LLM can read the error and recover. A
  tool failure never produces an `"ai.react.failed"` signal.
  """

  use Aikido.Directive
  require Ash.Tracer

  typed_struct do
    field :options, Aikido.Slices.AiReact.Options do
      description "Execution policy controlling the supervised tool attempt and its deadline."
      default %Aikido.Slices.AiReact.Options{}
      allow_nil? false
    end

    field :tool_call, :map do
      description "Model-issued tool call containing its identifier, name and arguments."
      allow_nil? false
    end

    field :registry, :map do
      description "Prepared native Ash AI callbacks indexed by the exposed tool names."
      allow_nil? false
      default %{}
    end

    field :tool_context, :map do
      description "Native Ash scope and application context passed to the tool callback."
      allow_nil? false
      default %{}
    end

    field :request_id, :string do
      description "Run identifier attached to the tool-result or failure signal."
      allow_nil? false
    end
  end

  alias Aikido.AgentServer
  alias Aikido.Signal
  alias Aikido.Slices.AiReact.Directives.ToolExec

  @impl true
  def exec(%ToolExec{} = directive, input_signal, state) do
    agent_pid = self()
    task_sup = Aikido.task_supervisor_name(state.aikido)
    source = "/agent/#{state.id}"
    agent_module = Map.get(state, :agent_module)

    inherited =
      if match?(%Aikido.Signal{}, input_signal), do: Aikido.Signal.ctx(input_signal), else: %{}

    context =
      Map.merge(Map.merge(directive.tool_context, inherited), %{
        agent_id: state.id,
        request_id: directive.request_id,
        tool_call_id: directive.tool_call.id,
        agent_resource:
          if(
            Spark.Dsl.is?(agent_module, Ash.Resource) &&
              Aikido.Ash.Agent in Spark.extensions(agent_module),
            do: agent_module
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

    tracers = Aikido.Signal.tracers(input_signal, state.aikido)
    transfer = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers)

    case Task.Supervisor.start_child(task_sup, fn ->
           Ash.ProcessHelpers.transfer_context(transfer)

           Ash.Tracer.span {:custom, :aikido_tool_call}, "aikido_tool_call", tracers do
             run_and_dispatch(directive, agent_pid, source, context, task_sup)
           end
         end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> dispatch_result(directive, {:error, reason}, agent_pid, source, context)
    end

    :ok
  end

  defp run_and_dispatch(%ToolExec{} = d, agent_pid, source, context, supervisor) do
    options = d.options

    result =
      Aikido.Slices.AiReact.Execution.run(
        agent_pid,
        d.request_id,
        supervisor,
        fn _notify, _attempt -> run_tool(d.tool_call, d.registry, context) end,
        tracer: context[:tracer],
        timeout: options.tool_timeout_ms,
        retries: options.tool_max_retries,
        backoff: options.retry_backoff_ms
      )

    dispatch_result(d, result, agent_pid, source, context)
  end

  defp dispatch_result(d, result, agent_pid, source, context) do
    content =
      case result do
        {:ok, content} -> content
        {:error, :timeout} -> Jason.encode!(%{error: "tool timeout"})
        {:error, :cancelled} -> Jason.encode!(%{error: "tool cancelled"})
        {:error, reason} -> Jason.encode!(%{error: AshAi.Tool.Errors.format(reason)})
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
        Aikido.Signal.put_ctx(
          signal,
          Map.new(Ash.Scope.to_opts(context, context: context[:context] || %{}))
        )
      )
  end

  defp run_tool(%{name: name, arguments: args}, registry, context) do
    ash_context =
      Map.put(Map.get(context, :context) || %{}, :aikido, Map.delete(context, :context))

    context = Map.put(context, :context, ash_context)

    case Map.fetch(registry, name) do
      {:ok, callback} ->
        case callback.(args, context) do
          {:ok, content, _raw} -> {:ok, content}
          {:error, content} -> {:ok, content}
        end

      :error ->
        {:ok, Jason.encode!(%{error: "tool not found: #{name}"})}
    end
  end
end
