defmodule AgentExamples.Source do
  @moduledoc "Exact source definitions shown alongside each runnable example."
  @root Path.expand("../../../..", __DIR__)
  @files Enum.flat_map(
           [
             "examples/agent_app/lib/agent_examples/agents/*.ex",
             "examples/agent_app/lib/agent_examples/slices/*.ex",
             "examples/agent_app/lib/agent_examples/ai/*.ex",
             "examples/agent_app/lib/agent_examples/**/implementation.ex",
             "examples/agent_app/lib/agent_examples/agents.ex",
             "examples/agent_app/lib/agent_examples/ai.ex",
             "examples/agent_app/lib/agent_examples/playground.ex",
             "lib/aikido/slices/ai_react.ex",
             "lib/aikido/slices/ai_worker.ex",
             "lib/aikido/slices/ai_worker/**/*.ex",
             "lib/aikido/slices/ai_react/**/*.ex",
             "lib/aikido/hooks.ex",
             "lib/aikido/ai/*.ex",
             "lib/aikido/slices/todo.ex",
             "lib/aikido/slices/todo/*.ex",
             "lib/aikido/hooks/*.ex",
             "lib/aikido/ash/ai.ex",
             "lib/aikido/ash/team/engine.ex"
           ],
           &Path.wildcard(Path.join(@root, &1))
         )
         |> Enum.uniq()

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
                   {:defmodule, metadata, [{:__aliases__, _, parts}, _]} ->
                     module = Module.concat(parts)
                     name = Enum.join(parts, ".")

                     category =
                       cond do
                         String.ends_with?(name, ".Implementation") ->
                           :action

                         String.contains?(file, "/agents/") ->
                           :agent

                         String.contains?(file, "agent_examples/slices/") ->
                           :slice

                         module in [
                           Aikido.Slices.AiReact,
                           Aikido.Slices.AiWorker,
                           Aikido.Slices.Todo
                         ] ->
                           :slice

                         String.contains?(file, "/actions/") ||
                             String.starts_with?(name, "Aikido.Slices.AiWorker.") ->
                           :action

                         String.contains?(file, "/directives/") || module == Aikido.Hooks.Execute ->
                           :directive

                         module == AgentExamples.Agents ->
                           :domain

                         true ->
                           :support
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

  @ai_names [
    AgentExamples.AI,
    AgentExamples.AI.Tools,
    AgentExamples.AI.Tools.Implementation,
    AgentExamples.AI.LuaSurface,
    AgentExamples.AI.ScriptedClient,
    AgentExamples.AI.StreamingClient,
    Aikido.AI.Options,
    Aikido.AI.Handoff,
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

    modules = modules ++ Enum.map(modules, &Module.concat(&1, Implementation))

    Enum.filter(@definitions, fn entry ->
      entry.module in modules ||
        (AgentExamples.Catalog.ai?(example) &&
           (entry.module in @ai_names || String.starts_with?(entry.name, "Aikido.Slices.AiReact.") ||
              String.starts_with?(entry.name, "Aikido.Hooks") ||
              String.starts_with?(entry.name, "Aikido.Slices.AiWorker.")))
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

  defp modules("conversation"),
    do: [Aikido.Slices.Todo, Aikido.Slices.Todo.Item, Aikido.Slices.Todo.Implementation]

  defp modules("counter"), do: []
  defp modules("checklist"), do: []
  defp modules("notebook"), do: [AgentExamples.Journal]
  defp modules("worker"), do: []

  defp modules("team"),
    do: [
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
      Aikido.Ash.Team.Engine
    ]

  defp modules("nested-teams"),
    do: [AgentExamples.Team | modules("team")]

  defp modules(_), do: []
  defp rank(:agent), do: 1
  defp rank(:slice), do: 2
  defp rank(:action), do: 3
  defp rank(:directive), do: 4
  defp rank(:domain), do: 5
  defp rank(_), do: 6
end
