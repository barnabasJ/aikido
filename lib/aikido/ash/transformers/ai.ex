defmodule Aikido.Ash.Transformers.AI do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder
  alias Ash.Resource.Actions.Argument
  alias Spark.Dsl.Transformer

  def before?(Aikido.Ash.Transformers.Agent), do: true
  def before?(_), do: false

  def transform(dsl) do
    if Aikido.Ash.Agent in Spark.extensions(dsl), do: build(dsl), else: {:ok, dsl}
  end

  defp build(dsl) do
    fields = [
      options: [Aikido.AI.Options, %{}, false],
      tools: [{:array, :atom}, [], false],
      tool_options: [{:array, :tuple}, [], false],
      hooks: [{:array, Aikido.Hooks.Hook}, [], false],
      tool_context: [:map, %{}, false],
      model: [:term, nil, true],
      client: [:atom, ReqLLM.Generation, false],
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
             arg(:request_id, :string, allow_nil?: false, default: &Ash.UUIDv7.generate/0)
           ]),
         {:ok, dsl} <- add_action(dsl, :cancel, [arg(:request_id, :string)]) do
      dsl =
        Transformer.add_entity(dsl, [:agent], %Aikido.Dsl.Agent.SliceMount{
          path: :ai,
          module: Aikido.Slices.AiReact,
          options: []
        })

      dsl =
        Transformer.add_entity(dsl, [:agent], %Aikido.Dsl.Agent.SliceMount{
          path: :work,
          module: Aikido.Slices.AiWorker,
          options: []
        })

      {:ok, Transformer.persist(dsl, :aikido_ai?, true)}
    end
  end

  defp add_action(dsl, name, arguments) do
    dsl =
      Transformer.add_entity(dsl, [:agent], %Aikido.Ash.Agent.Signal{
        name: name,
        type: "ai.react.#{name}",
        target: {Aikido.Slices.AiReact, name}
      })

    Builder.add_new_action(dsl, :action, name,
      returns: :map,
      arguments: arguments
    )
  end

  defp arg(name, type, opts \\ []),
    do:
      struct(
        Argument,
        Keyword.merge([name: name, type: Ash.Type.get_type(type), public?: true], opts)
      )
end
