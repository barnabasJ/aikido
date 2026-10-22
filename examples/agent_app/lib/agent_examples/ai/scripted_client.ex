defmodule AgentExamples.AI.ScriptedClient do
  @moduledoc """
  A deterministic model substitute that exercises real tools and signal flows.

  An `orchestrate:` request starts a team specialist, delegates to the fixed
  analyst (which starts and delegates to its own helper), then asks the fixed
  reviewer and the specialist. Ordinary requests use text_stats and team_roster.
  """
  @behaviour Aikido.AiReact.Client

  @impl true
  def generate_text(_model, messages, options) do
    messages = current_request_messages(messages)
    query = messages |> Enum.find(&(&1.role == :user)) |> message_text()
    results = Enum.filter(messages, &(&1.role == :tool))
    tools = Keyword.fetch!(options, :tools) |> Enum.map(& &1.name)

    cond do
      tools == [] && String.starts_with?(query, "This conversation is about to be replaced") ->
        handoff_response()

      String.starts_with?(query, "orchestrate:") &&
          ("spawn_worker" in tools || "run_lua" in tools) ->
        plan_team_delegation(results, query, "run_lua" in tools)

      String.starts_with?(query, "expand:") && ("spawn_worker" in tools || "run_lua" in tools) ->
        plan_worker_delegation(results, query, "run_lua" in tools)

      results == [] ->
        initial_tool_response(tools, query)

      true ->
        respond_with_tool_results(results)
    end
  end

  defp current_request_messages(messages) do
    current =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {message, _} ->
        message.role == :user && !String.starts_with?(message_text(message), "[Hook context:")
      end)

    Enum.drop(messages, if(current, do: elem(current, 1), else: 0))
  end

  defp handoff_response do
    {:ok,
     %ReqLLM.Response{
       id: "scripted",
       model: "offline",
       context: ReqLLM.Context.new(),
       message:
         ReqLLM.Context.assistant(
           "Offline handoff demonstration. Follow the system instructions and continue the conversation with the supplied tools. Next action: process the latest user instruction and report the result.",
           tool_calls: []
         ),
       finish_reason: :stop
     }}
  end

  defp initial_tool_response(tools, query) do
    calls =
      for name <- tools,
          name in ["text_stats", "team_roster", "stamp", "run_lua"],
          do: new_tool_call(name, tool_arguments(name, query))

    {:ok,
     %ReqLLM.Response{
       id: "scripted",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant("", tool_calls: calls),
       finish_reason: :tool_calls
     }}
  end

  defp tool_arguments(name, query) when name in ["text_stats", "stamp"],
    do: %{"input" => %{"text" => query}}

  defp tool_arguments("run_lua", _query),
    do: %{
      "input" => %{"script" => "return analysis.text_stats({input = {text = 'Lua calls Ash'}})"}
    }

  defp tool_arguments(_, _), do: %{}

  defp plan_team_delegation(results, query, lua?) do
    task = String.trim_leading(query, "orchestrate:") |> String.trim()

    operations = [
      {"spawn_worker", %{name: "specialist", specialty: "independent verification"}},
      {"delegate", %{member: "analyst", text: "expand: #{task}"}},
      {"delegate", %{member: "reviewer", text: task}},
      {"delegate", %{member: "specialist", text: task}}
    ]

    request_next_team_operation(results, operations, lua?)
  end

  defp plan_worker_delegation(results, query, lua?) do
    task = String.trim_leading(query, "expand:") |> String.trim()

    operations = [
      {"spawn_worker", %{name: "analyst-helper", specialty: "word counting"}},
      {"delegate", %{member: "analyst-helper", text: task}}
    ]

    request_next_team_operation(results, operations, lua?)
  end

  defp request_next_team_operation([], _operations, lua?),
    do: respond_with_team_tool("team_roster", %{}, lua?)

  defp request_next_team_operation([roster | _] = results, operations, lua?) do
    roster = roster |> message_text() |> Jason.decode!()
    members = Map.get(roster["result"] || roster, "members", [])

    operations =
      Enum.reject(operations, fn
        {"spawn_worker", %{name: name}} -> name in members
        _ -> false
      end)

    case Enum.at(operations, length(results) - 1) do
      {name, arguments} -> respond_with_team_tool(name, arguments, lua?)
      nil -> respond_with_tool_results(results)
    end
  end

  defp respond_with_team_tool(name, arguments, false), do: respond_with_tool_call(name, arguments)

  defp respond_with_team_tool(name, arguments, true) do
    action =
      case name do
        "team_roster" -> "members"
        "spawn_worker" -> "spawn"
        "delegate" -> "delegate"
      end

    fields =
      Enum.map_join(arguments, ", ", fn {key, value} -> "#{key} = #{lua_string(value)}" end)

    respond_with_tool_call("run_lua", %{
      script: "return assert(agents.#{action}({input = {#{fields}}}))"
    })
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

  defp respond_with_tool_call(name, arguments),
    do:
      {:ok,
       %ReqLLM.Response{
         id: "scripted",
         model: "offline",
         context: ReqLLM.Context.new(),
         message:
           ReqLLM.Context.assistant("",
             tool_calls: [
               new_tool_call(name, %{
                 "input" => Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
               })
             ]
           ),
         finish_reason: :tool_calls
       }}

  defp new_tool_call(name, arguments),
    do: %{id: Ash.UUIDv7.generate(), name: name, arguments: arguments}

  defp format_lua_result(%{"words" => words, "characters" => characters}),
    do: "Words: #{words}; characters: #{characters}."

  defp format_lua_result(%{"member" => member, "result" => result}),
    do: "#{member}: #{result}"

  defp format_lua_result(%{"status" => "started", "member" => member}),
    do: "Started #{member}."

  defp format_lua_result(result), do: Jason.encode!(result)

  defp respond_with_tool_results(results) do
    output =
      Enum.map_join(results, "\n", fn message ->
        result = message |> message_text() |> Jason.decode!()

        case result do
          %{"words" => words, "characters" => characters} ->
            "Words: #{words}; characters: #{characters}."

          %{"label" => label, "text" => text} ->
            "#{label}: #{text}"

          %{"result" => result, "error" => nil} ->
            "Lua: #{format_lua_result(result)}"

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

    {:ok,
     %ReqLLM.Response{
       id: "scripted",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant(output, tool_calls: []),
       finish_reason: :stop
     }}
  end

  defp message_text(message), do: Enum.map_join(message.content, "", &(&1.text || ""))
end
