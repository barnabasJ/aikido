defmodule AgentExamples.AI.ScriptedClient do
  @moduledoc """
  A deterministic model substitute that exercises real tools and signal flows.

  An `orchestrate:` request starts a team specialist, delegates to the fixed
  analyst (which starts and delegates to its own helper), then asks the fixed
  reviewer and the specialist. Ordinary requests use text_stats and team_roster.
  """
  @behaviour Aikido.AI.Client
  alias Aikido.Slices.AiReact.Turn

  @impl true
  def generate_text(_model, messages, options) do
    current =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {message, _} ->
        message.role == :user && !String.starts_with?(text(message), "[Hook context:")
      end)

    messages = Enum.drop(messages, if(current, do: elem(current, 1), else: 0))
    query = messages |> Enum.find(&(&1.role == :user)) |> text()
    results = Enum.filter(messages, &(&1.role == :tool))
    tools = Keyword.fetch!(options, :tools) |> Enum.map(& &1.name)

    cond do
      tools == [] && String.starts_with?(query, "This conversation is about to be replaced") ->
        {:ok,
         %Turn{
           text:
             "Offline handoff demonstration. Follow the system instructions and continue the conversation with the supplied tools. Next action: process the latest user instruction and report the result."
         }}

      String.starts_with?(query, "orchestrate:") &&
          ("spawn_worker" in tools || "run_lua" in tools) ->
        orchestrate(results, query, "run_lua" in tools)

      String.starts_with?(query, "expand:") && ("spawn_worker" in tools || "run_lua" in tools) ->
        expand(results, query, "run_lua" in tools)

      results == [] ->
        calls =
          for name <- tools,
              name in ["text_stats", "team_roster", "stamp", "ash_text_stats", "run_lua"],
              do: call(name, arguments(name, query))

        {:ok, %Turn{type: :tool_calls, tool_calls: calls}}

      true ->
        final(results)
    end
  end

  defp arguments(name, query) when name in ["ash_text_stats", "text_stats", "stamp"],
    do: %{"input" => %{"text" => query}}

  defp arguments("run_lua", _query),
    do: %{
      "input" => %{"script" => "return analysis.text_stats({input = {text = 'Lua calls Ash'}})"}
    }

  defp arguments(_, _), do: %{}

  defp orchestrate(results, query, lua?) do
    task = String.trim_leading(query, "orchestrate:") |> String.trim()

    case length(results) do
      0 ->
        team_tool(
          "spawn_worker",
          %{name: "specialist", specialty: "independent verification"},
          lua?
        )

      1 ->
        team_tool("delegate", %{member: "analyst", text: "expand: #{task}"}, lua?)

      2 ->
        team_tool("delegate", %{member: "reviewer", text: task}, lua?)

      3 ->
        team_tool("delegate", %{member: "specialist", text: task}, lua?)

      _ ->
        final(results)
    end
  end

  defp expand(results, query, lua?) do
    task = String.trim_leading(query, "expand:") |> String.trim()

    case length(results) do
      0 -> team_tool("spawn_worker", %{name: "analyst-helper", specialty: "word counting"}, lua?)
      1 -> team_tool("delegate", %{member: "analyst-helper", text: task}, lua?)
      _ -> final(results)
    end
  end

  defp team_tool(name, arguments, false), do: tool(name, arguments)

  defp team_tool(name, arguments, true) do
    action =
      case name do
        "spawn_worker" -> "spawn"
        "delegate" -> "delegate"
      end

    fields =
      Enum.map_join(arguments, ", ", fn {key, value} -> "#{key} = #{lua_string(value)}" end)

    tool("run_lua", %{script: "return assert(agents.#{action}({input = {#{fields}}}))"})
  end

  # Long strings avoid interpreting prompts as Lua source, including embedded quotes.
  defp lua_string(value) do
    separator =
      Stream.iterate(0, &(&1 + 1))
      |> Enum.find_value(fn size ->
        separator = String.duplicate("=", size)
        if !String.contains?(value, "]#{separator}]"), do: separator
      end)

    "string.sub([#{separator}[_#{value}]#{separator}], 2)"
  end

  defp tool(name, arguments),
    do:
      {:ok,
       %Turn{
         type: :tool_calls,
         tool_calls: [
           call(name, %{
             "input" => Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
           })
         ]
       }}

  defp call(name, arguments),
    do: %{id: Aikido.Util.generate_id(), name: name, arguments: arguments}

  defp final(results) do
    output =
      Enum.map_join(results, "\n", fn message ->
        result = message |> text() |> Jason.decode!()

        case result do
          %{"words" => words, "characters" => characters} ->
            "Words: #{words}; characters: #{characters}."

          %{"label" => label, "text" => text} ->
            "#{label}: #{text}"

          %{"result" => result, "error" => nil} ->
            "Lua: #{Jason.encode!(result)}"

          %{"members" => members} ->
            "Team: #{Enum.join(members, ", ")}."

          %{"result" => result, "member" => member} ->
            "#{member}: #{result}"

          %{"status" => "started", "member" => member} ->
            "Started #{member}."

          %{"error" => error} ->
            "Tool error: #{if is_binary(error), do: error, else: Jason.encode!(error)}"
        end
      end)

    {:ok, %Turn{type: :final_answer, text: output}}
  end

  defp text(message), do: Enum.map_join(message.content, "", &(&1.text || ""))
end
