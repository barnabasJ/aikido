defmodule Aikido.NativeToolResultsTest.Agent do
  use Aikido.Agent

  agent do
    name "native_tool_results"
    slice :ai, Aikido.Slices.AiReact
  end
end

defmodule Aikido.NativeToolResultsTest.Client do
  def generate_text(_, messages, opts) do
    tool_messages = Enum.filter(messages, &(&1.role == :tool))
    done? = tool_messages != []

    if done?, do: send(opts[:observer], {:native_tool_messages, tool_messages})

    calls =
      if done? do
        []
      else
        for {_, index} <- Enum.with_index(opts[:native_results]) do
          ReqLLM.ToolCall.new("native_#{index}", "native_output", Jason.encode!(%{index: index}))
        end
      end

    {:ok,
     struct!(ReqLLM.Response,
       id: "native-results",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant(if(done?, do: "complete", else: ""), tool_calls: calls),
       finish_reason: if(done?, do: :stop, else: :tool_calls)
     )}
  end

  def output(%{"index" => index}, context),
    do: Enum.at(context.context.shared.results, index)

  def unused(_args), do: {:ok, nil}
end

defmodule Aikido.NativeToolResultsTest do
  use AikidoTest.Case, async: true
  alias ReqLLM.Message.ContentPart
  alias Aikido.NativeToolResultsTest.Client

  test "native Ash AI results fan in and retain structured output and model content", ctx do
    structured = %ReqLLM.ToolResult{
      output: %{document_id: "doc-42", pages: 3},
      content: [
        ContentPart.text("Document attached"),
        ContentPart.image_url("https://example.test/image.png")
      ],
      metadata: %{provider_native: %{request_id: "provider-42"}}
    }

    results = [
      {:ok, "text"},
      {:ok, %{count: 3}},
      {:ok, 42},
      {:ok, nil},
      {:ok,
       [
         ContentPart.text("part", %{provider: :example}),
         ContentPart.image_url("https://example.test/part.png")
       ]},
      {:ok, structured},
      {:error, %{error: "native tool error"}}
    ]

    tool =
      ReqLLM.Tool.new!(
        name: "native_output",
        description: "Return one native tool value",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{"index" => %{"type" => "integer"}},
          "required" => ["index"]
        },
        callback: &Client.unused/1
      )

    pid = start_server(ctx, Aikido.NativeToolResultsTest.Agent)

    assert {:ok, "complete"} =
             Aikido.AI.ask_sync(pid, "return native results",
               model: "offline",
               client: Client,
               llm_opts: [observer: self(), native_results: results],
               tool_options: [extra_tools: [{tool, &Client.output/2}]],
               tool_context: %{context: %{shared: %{results: results}}}
             )

    assert_receive {:native_tool_messages, messages}, 5_000
    assert length(messages) == length(results)
    by_id = Map.new(messages, &{&1.tool_call_id, &1})

    for {{_status, value}, index} <- Enum.with_index(results) do
      id = "native_#{index}"
      assert by_id[id] == ReqLLM.Context.tool_result(id, "native_output", value)
    end

    assert ReqLLM.ToolResult.output_from_message(by_id["native_5"]) == structured.output
    assert by_id["native_5"].content == structured.content
    assert by_id["native_5"].metadata.provider_native == structured.metadata.provider_native
    assert by_id["native_4"].content == elem(Enum.at(results, 4), 1)

    assert {:ok, ai} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
    assert ai.status == :completed
    assert ai.iteration == 2
    assert ai.pending_tool_calls == []
    assert ai.tool_results_received == []
    assert ai.estimated_tokens == Aikido.AI.Context.estimate_tokens(ai.context)
  end
end
