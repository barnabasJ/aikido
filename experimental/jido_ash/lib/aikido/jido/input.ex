defmodule Aikido.Jido.Input do
  @moduledoc false

  def signal(input, agent, helper, names) do
    # Ash casts for its boundary and authorization. Jido gets original values so
    # its strict Zoi types, defaults, refinements and unknown-key policy survive.
    data =
      input.params
      |> Map.drop([
        :server,
        "server",
        :runtime_options,
        "runtime_options",
        :signal_options,
        "signal_options"
      ])
      |> Map.new(fn {key, value} ->
        {Enum.find(names, key, &(to_string(&1) == to_string(key))), value}
      end)

    apply(agent, helper, [data, input.arguments.signal_options])
  end

  def runtime_options(input, context) do
    options = input.arguments.runtime_options

    if Keyword.keyword?(options) do
      native_context = %{
        actor: context.actor,
        tenant: context.tenant,
        authorize?: context.authorize?,
        domain: context.domain,
        tracer: context.tracer,
        span_contexts: Map.new(List.wrap(context.tracer), &{&1, Ash.Tracer.get_span_context(&1)}),
        context: context.source_context
      }

      caller_context = Keyword.get(options, :context) || %{}

      if is_map(caller_context) or Keyword.keyword?(caller_context) do
        {:ok,
         Keyword.put(options, :context, Map.put(Map.new(caller_context), :ash, native_context))}
      else
        {:error, ArgumentError.exception("Jido context must be a map or keyword list")}
      end
    else
      {:error, ArgumentError.exception("Jido runtime_options must be a keyword list")}
    end
  end
end
