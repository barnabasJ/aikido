defmodule AgentExamples.AI.Demo do
  @moduledoc "Run `mix ai.demo` offline or `mix ai.live` with z.ai credentials."
  alias AgentExamples.{Agents, AI}

  def run do
    with_resource(
      Agents.assistant_start!(
        AI.offline(%{
          tool_context: %{context: %{stamp_label: "single"}},
          tools: AI.Tools.for_assistant()
        })
      ),
      fn assistant ->
        {:ok, answer} = AI.ask(assistant, "Signals carry results")
        IO.puts("Single agent: #{answer}")
      end
    )

    with_resource(
      Agents.research_team_start!(
        AI.offline(%{
          tool_context: %{context: %{stamp_label: "research"}},
          tools: AI.Tools.for_assistant() ++ AI.Tools.from_ash_ai()
        })
      ),
      fn team ->
        {:ok, answer} = AI.ask(team, "orchestrate: Signals carry results")
        IO.puts("Orchestrator:\n#{answer}")
        team = Aikido.Ash.inspect!(AgentExamples.ResearchTeam, team.id)
        IO.inspect(Map.keys(team.team.members), label: "Fixed and dynamic workers")
        IO.inspect(team.team.topology.nodes["analyst-helper"].owner, label: "Helper's owner")
      end
    )

    :ok
  end

  def live do
    # Never store the key in a resource or print it. ReqLLM reads ZAI_API_KEY.
    if System.get_env("ZAI_API_KEY") in [nil, ""],
      do: raise("Set ZAI_API_KEY before running mix ai.live")

    specification = System.fetch_env!("AIKIDO_AI_MODEL")

    {provider, id} =
      case String.split(specification, ":", parts: 2) do
        ["zai", id] -> {:zai, id}
        ["zai_coder", id] -> {:zai_coder, id}
        _ -> raise "AIKIDO_AI_MODEL must be zai:<model-id> or zai_coder:<model-id>"
      end

    # Inline specs support model IDs newer than the installed model catalog.
    configuration = %{
      model: %{provider: provider, id: id},
      tool_context: %{context: %{stamp_label: "live"}},
      tools: AI.Tools.for_assistant() ++ AI.Tools.from_ash_ai()
    }

    with_resource(Agents.research_team_start!(configuration), fn team ->
      {:ok, answer} =
        AI.ask(
          team,
          "Analyze 'Signals carry results'. Ask the analyst to create a helper and delegate counting to it. Create an independent specialist yourself. Have the reviewer check the results, and report the evidence.",
          timeout: 180_000
        )

      IO.puts(answer)
    end)

    :ok
  end

  defp with_resource(resource, fun) do
    try do
      fun.(resource)
    after
      Aikido.Ash.stop!(resource)
    end
  end
end
