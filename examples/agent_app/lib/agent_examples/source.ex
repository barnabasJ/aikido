defmodule AgentExamples.Source do
  @moduledoc "Exact source definitions shown alongside each runnable example."
  @root Path.expand("../../../..", __DIR__)
  @files Enum.flat_map(
           [
             "examples/agent_app/lib/agent_examples/**/*.ex",
             "lib/aikido/ai.ex",
             "lib/aikido/slices/ai_react.ex",
             "lib/aikido/slices/ai_react/**/*.ex",
             "lib/aikido/slices/ai_worker.ex",
             "lib/aikido/slices/ai_worker/**/*.ex",
             "lib/aikido/slices/todo.ex",
             "lib/aikido/slices/todo/**/*.ex",
             "lib/aikido/ash/ai.ex",
             "lib/aikido/ash/team.ex",
             "lib/aikido/ash/team/*.ex",
             "lib/aikido/ash/team/actions/*.ex"
           ],
           &Path.wildcard(Path.join(@root, &1))
         )
         |> Enum.uniq()
         |> Enum.reject(&(&1 == __ENV__.file))

  for file <- @files, do: @external_resource(file)

  @definitions Enum.flat_map(@files, fn file ->
                 source = File.read!(file)
                 lines = String.split(source, "\n")
                 ast = Code.string_to_quoted!(source, columns: true, token_metadata: true)

                 nodes =
                   case ast do
                     {:__block__, _, nodes} -> nodes
                     node -> [node]
                   end

                 Enum.flat_map(nodes, fn
                   {:defmodule, metadata, [{:__aliases__, _, parts}, [do: body]]} ->
                     module = Module.concat(parts)
                     name = Enum.join(parts, ".")

                     {_body, contracts} =
                       Macro.prewalk(body, [], fn
                         {:use, _, [{:__aliases__, _, used} | options]} = node, contracts ->
                           extensions =
                             case options do
                               [options] when is_list(options) ->
                                 Keyword.get(options, :extensions, [])

                               _ ->
                                 []
                             end

                           extensions =
                             for {:__aliases__, _, extension} <- extensions,
                                 do: Module.concat(extension)

                           {node, [Module.concat(used) | extensions ++ contracts]}

                         node, contracts ->
                           {node, contracts}
                       end)

                     category =
                       cond do
                         Aikido.Signal in contracts -> :signal
                         Aikido.Ash.Agent in contracts || Aikido.Agent in contracts -> :agent
                         Aikido.Ash.Slice in contracts || Aikido.Slice in contracts -> :slice
                         Aikido.Directive in contracts -> :directive
                         Ash.Resource.Actions.Implementation in contracts -> :action
                         Ash.Domain in contracts -> :domain
                         true -> :support
                       end

                     [
                       %{
                         module: module,
                         name: name,
                         category: category,
                         path: Path.relative_to(file, @root),
                         code:
                           lines
                           |> Enum.slice((metadata[:line] - 1)..(metadata[:end][:line] - 1))
                           |> Enum.join("\n")
                       }
                     ]

                   _ ->
                     []
                 end)
               end)

  @ai_owners [
    AgentExamples.AI,
    Aikido.AI,
    Aikido.Ash.AI,
    Aikido.Slices.AiReact,
    Aikido.Slices.AiWorker
  ]

  def for_example(example) do
    modules =
      modules(example.slug) ++
        [
          example.resource,
          AgentExamples.Agents
        ]

    Enum.filter(@definitions, fn entry ->
      entry.module in modules ||
        Enum.any?(modules, &String.starts_with?(entry.name, inspect(&1) <> ".")) ||
        (AgentExamples.Catalog.ai?(example) &&
           Enum.any?(@ai_owners, fn owner ->
             entry.module == owner || String.starts_with?(entry.name, inspect(owner) <> ".")
           end))
    end)
    |> Enum.sort_by(fn entry ->
      {if(entry.module == example.resource, do: 0, else: rank(entry.category)), entry.name}
    end)
    |> Enum.map(
      &Map.merge(&1, %{
        open?: &1.category in [:agent, :slice],
        id: "definition-" <> String.replace(&1.name, ".", "-")
      })
    )
  end

  defp modules("hook-requests"), do: [AgentExamples.Playground]

  defp modules("conversation"), do: [Aikido.Slices.Todo]

  defp modules("counter"), do: []
  defp modules("checklist"), do: []
  defp modules("notebook"), do: [AgentExamples.Journal]
  defp modules("worker"), do: []

  defp modules("team"),
    do: [
      Aikido.Ash.Team,
      AgentExamples.Counter,
      AgentExamples.Notebook,
      AgentExamples.Worker,
      AgentExamples.Journal
    ]

  defp modules("research-team"),
    do: [
      AgentExamples.Researcher,
      AgentExamples.Reviewer,
      AgentExamples.ResearchSquad,
      Aikido.Ash.Team
    ]

  defp modules("nested-teams"),
    do: [AgentExamples.Team | modules("team")]

  defp modules(_), do: []
  defp rank(:agent), do: 1
  defp rank(:slice), do: 2
  defp rank(:signal), do: 3
  defp rank(:action), do: 4
  defp rank(:directive), do: 5
  defp rank(:domain), do: 6
  defp rank(_), do: 7
end
