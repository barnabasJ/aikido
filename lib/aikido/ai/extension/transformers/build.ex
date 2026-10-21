defmodule Aikido.AI.Extension.Transformers.Build do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def before?(Aikido.Agent.Extension.Transformers.Build), do: true
  def before?(_), do: false

  def transform(dsl) do
    if Aikido.Agent.Extension in Spark.extensions(dsl), do: build(dsl), else: {:ok, dsl}
  end

  defp build(dsl) do
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

    with {:ok, dsl} <-
           Enum.reduce_while(fields, {:ok, dsl}, fn {name, [type, default, nullable]},
                                                    {:ok, dsl} ->
             options = [
               default:
                 if(name in [:tools, :tool_context],
                   do: default,
                   else: Transformer.get_option(dsl, [:ai], name, default)
                 ),
               allow_nil?: nullable,
               public?: true
             ]

             options =
               case name do
                 :max_iterations ->
                   Keyword.put(options, :constraints, min: 1)

                 name when name in [:llm_opts, :tool_options] ->
                   Keyword.put(options, :constraints,
                     items: [fields: [key: [type: :atom], value: [type: :term]]]
                   )

                 _ ->
                   options
               end

             case Builder.add_new_attribute(dsl, name, type, options) do
               {:ok, dsl} -> {:cont, {:ok, dsl}}
               error -> {:halt, error}
             end
           end),
         {:ok, dsl} <-
           add_action(dsl, :ask, [
             arg(:query, :string, allow_nil?: false),
             arg(:metadata, :map, default: %{}),
             arg(:request_id, :string, allow_nil?: false, default: &Ash.UUIDv7.generate/0)
           ]),
         {:ok, dsl} <- add_action(dsl, :cancel, [arg(:request_id, :string)]) do
      dsl =
        Transformer.add_entity(dsl, [:agent], %Aikido.Agent.SliceMount{
          path: :ai,
          module: Aikido.AiReact.Slice,
          options: []
        })

      dsl =
        Transformer.add_entity(dsl, [:agent], %Aikido.Agent.SliceMount{
          path: :work,
          module: Aikido.AiWorker.Slice,
          options: []
        })

      {:ok, Transformer.persist(dsl, :aikido_ai?, true)}
    end
  end

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
