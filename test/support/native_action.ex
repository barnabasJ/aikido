defmodule AikidoTest.NativeAction do
  @moduledoc false

  def run(reference, signal, state, context) do
    {resource, action} = Aikido.ActionRef.normalize(reference)
    definition = Ash.Resource.Info.action(resource, action)
    params = signal.data || %{}

    arguments =
      if Enum.any?(definition.arguments, &(&1.name == :data)),
        do: %{data: params, state: state},
        else: Map.put(params, :state, state)

    runtime = Map.put(context, :signal, signal)

    opts =
      Ash.Scope.to_opts(context, context: Map.put(context[:context] || %{}, :aikido, runtime))

    resource
    |> Ash.ActionInput.for_action(
      action,
      arguments,
      Keyword.put(opts, :skip_unknown_inputs, [:*])
    )
    |> Ash.run_action(opts)
    |> case do
      {:ok, value} ->
        case Aikido.ActionResult.new(value) do
          {:ok, result} -> {:ok, result.state, result.directives}
          {:error, error} -> {:error, Ash.Error.to_error_class(error)}
        end

      error ->
        error
    end
  end

  # Exercise the same state-application code as AgentServer without running I/O.
  def apply(module, agent, actions, opts \\ []) do
    signal =
      opts[:input_signal] ||
        struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")

    ctx =
      signal
      |> Aikido.SignalCtx.ctx()
      |> Map.merge(opts[:ctx] || %{})
      |> Map.merge(%{agent_module: module, agent: agent, agent_id: agent.id})

    targets =
      actions
      |> List.wrap()
      |> Enum.map(fn
        {resource, action} = reference when is_atom(resource) and is_atom(action) ->
          {reference, %{}}

        {reference, params} when is_map(params) ->
          {reference, params}

        reference when is_atom(reference) ->
          {reference, %{}}

        _ ->
          raise ArgumentError, "Invalid action"
      end)

    case Aikido.AgentServer.apply_actions(signal, ctx, targets) do
      {:ok, ctx, directives} -> {:ok, ctx.agent, directives}
      {:error, _, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, Aikido.Error.validation_error("Invalid action")}
  end
end
