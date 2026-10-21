defmodule Aikido.AI.Extension.Transformers.Build do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def before?(Aikido.Agent.Extension.Transformers.Build), do: true
  def before?(_), do: false

  def transform(dsl) do
    if Aikido.Agent.Extension in Spark.extensions(dsl),
      do: add_ai_configuration_and_slice_mounts(dsl),
      else: {:ok, dsl}
  end

  defp add_ai_configuration_and_slice_mounts(dsl) do
    with {:ok, dsl} <- add_ai_attributes(dsl),
         {:ok, dsl} <- add_ask_command(dsl),
         {:ok, dsl} <- add_action(dsl, :cancel, [arg(:request_id, :string)]) do
      {:ok,
       dsl
       |> mount_ai_slices()
       |> Transformer.persist(:aikido_ai?, true)}
    end
  end

  defp add_ask_command(dsl) do
    add_action(dsl, :ask, [
      arg(:query, :string, allow_nil?: false),
      arg(:metadata, :map, default: %{}),
      arg(:request_id, :string, allow_nil?: false, default: &Ash.UUIDv7.generate/0)
    ])
  end

  defp mount_ai_slices(dsl) do
    Enum.reduce([ai: Aikido.AiReact.Slice, work: Aikido.AiWorker.Slice], dsl, fn {path, module},
                                                                                 dsl ->
      Transformer.add_entity(dsl, [:agent], %Aikido.Agent.SliceMount{
        path: path,
        module: module,
        options: []
      })
    end)
  end

  defp add_ai_attributes(dsl) do
    fields = [
      options: [Aikido.AiReact.Options, %{}, false],
      tools: [{:array, :atom}, [], false],
      tool_options: [{:array, :tuple}, [], false],
      hooks: [{:array, Aikido.AiReact.Hooks.Hook}, [], false],
      tool_context: [:map, %{}, false],
      model: [:term, nil, true],
      client: [:module, ReqLLM.Generation, false],
      llm_opts: [{:array, :tuple}, [], false],
      system_prompt: [:string, nil, true],
      max_iterations: [:integer, 10, false]
    ]

    Enum.reduce_while(fields, {:ok, dsl}, fn {name, [type, default, nullable]}, {:ok, dsl} ->
      options = attribute_options(dsl, name, default, nullable)

      case Builder.add_new_attribute(dsl, name, type, options) do
        {:ok, dsl} -> {:cont, {:ok, dsl}}
        error -> {:halt, error}
      end
    end)
  end

  defp attribute_options(dsl, name, default, nullable) do
    default =
      if name in [:tools, :tool_context],
        do: default,
        else: Transformer.get_option(dsl, [:ai], name, default)

    [default: default, allow_nil?: nullable, public?: true]
    |> add_attribute_constraints(name)
  end

  defp add_attribute_constraints(options, :max_iterations),
    do: Keyword.put(options, :constraints, min: 1)

  defp add_attribute_constraints(options, name) when name in [:llm_opts, :tool_options],
    do:
      Keyword.put(options, :constraints,
        items: [fields: [key: [type: :atom], value: [type: :term]]]
      )

  defp add_attribute_constraints(options, _name), do: options

  defp add_action(dsl, name, arguments) do
    dsl =
      Transformer.add_entity(dsl, [:agent], %Aikido.Agent.Route{
        name: name,
        public?: true,
        type: "ai.react.#{name}",
        action: {Aikido.AiReact.Slice, name}
      })

    Builder.add_new_action(dsl, :action, name,
      returns: :map,
      arguments: arguments
    )
  end

  defp arg(name, type, opts \\ []) do
    {:ok, argument} = Builder.build_action_argument(name, type, opts)
    argument
  end
end
