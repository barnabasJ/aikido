defmodule Aikido.ProviderPressureTest.Agent do
  use Aikido.Agent

  agent do
    name "provider_pressure"
    slice :ai, Aikido.AiReact.Slice
  end
end

defmodule Aikido.ProviderPressureTest.Client do
  @spec generate_text(model :: term(), messages :: list(), options :: keyword()) :: term()
  def generate_text(model, messages, options) do
    send(options[:observer], {:provider_request, self(), model, messages, options[:tools]})

    receive do
      {:provider_answer, result} -> result
    after
      5_000 -> {:error, :provider_fixture_timeout}
    end
  end

  @spec stream_text(model :: term(), messages :: list(), options :: keyword()) :: term()
  def stream_text(model, messages, options) do
    send(options[:observer], {:provider_stream_request, self(), model, messages, options[:tools]})

    receive do
      {:provider_stream_answer, text} ->
        {:ok, metadata} =
          ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
            %{usage: %{input_tokens: 100}, finish_reason: :stop}
          end)

        {:ok,
         %ReqLLM.StreamResponse{
           stream: [ReqLLM.StreamChunk.text(text)],
           metadata_handle: metadata,
           cancel: fn -> :ok end,
           model: %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"},
           context: ReqLLM.Context.new(messages)
         }}
    after
      5_000 -> {:error, :provider_stream_fixture_timeout}
    end
  end
end

defmodule Aikido.ProviderPressureTest.Prepare do
  use Ash.Resource.Actions.Implementation

  @impl Ash.Resource.Actions.Implementation
  @spec run(input :: term(), opts :: keyword(), context :: term()) :: {:ok, keyword()}
  def run(input, _opts, _context) do
    metadata = input.arguments.metadata
    observer = metadata.observer
    variant = metadata[:variant] || :base
    callback_id = make_ref()
    send(observer, {:prepared_tool, variant, callback_id, self()})

    if metadata[:hold] do
      receive do
        :release -> :ok
      after
        5_000 -> raise "preparation_fixture_timeout"
      end
    end

    schema_type = if variant == :schema, do: "string", else: "integer"
    description = if variant == :description, do: "pressure probe revised", else: "pressure probe"

    provider_options =
      if variant == :provider_options, do: %{openai: %{defer_loading: true}}, else: %{}

    tool =
      ReqLLM.Tool.new!(
        name: "pressure_probe",
        description: description,
        parameter_schema: %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => schema_type}}
        },
        provider_options: provider_options,
        callback: fn _arguments -> {:ok, callback_id} end
      )

    {:ok, Keyword.put(input.arguments.options, :extra_tools, [tool])}
  end
end

defmodule Aikido.ProviderPressureTest.Preparation do
  use Ash.Resource, domain: Aikido.RuntimeDomain

  actions do
    action :prepare, :term do
      argument :options, {:array, :tuple},
        constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]

      argument :metadata, :map
      run Aikido.ProviderPressureTest.Prepare
    end
  end
end

defmodule Aikido.ProviderPressureTest.OtherClient do
  @spec generate_text(model :: term(), messages :: list(), options :: keyword()) :: term()
  def generate_text(model, messages, options),
    do: Aikido.ProviderPressureTest.Client.generate_text(model, messages, options)
end

defmodule Aikido.ProviderPressureTest do
  use AikidoTest.Case, async: false

  alias Aikido.ProviderPressureTest.{Agent, Client, OtherClient}

  test "high reported pressure causes first new-request call to hand off and keeps its query once",
       ctx do
    pid = start_server(ctx, Agent)
    first = ask(pid, "first", options())
    assert_receive {:provider_request, provider, "offline", messages, [_]}, 5_000
    assert text(List.last(messages)) == "first"
    answer(provider, "first answer", %{input_tokens: 4_400, output_tokens: 5})
    assert {:ok, "first answer"} = Task.await(first, 5_000)
    assert {:ok, before} = ai(pid)
    assert before.last_input_tokens == 4_400
    assert before.estimated_tokens < 4_000
    assert is_binary(before.last_input_shape)

    next = ask(pid, "new driving query", options())
    assert_receive {:provider_request, writer, "offline", handoff, []}, 5_000
    assert text(List.last(handoff)) =~ "ONLY thing your successor receives"
    assert Enum.count(handoff, &(text(&1) == "new driving query")) == 1
    answer(writer, "Decision: continue with the native tool.", %{input_tokens: 4_450})
    assert_receive {:provider_request, successor, "offline", fresh, [_]}, 5_000
    assert Enum.map(fresh, & &1.role) == [:system, :user, :user]
    assert text(hd(fresh)) == "Keep the standing procedure."
    assert text(Enum.at(fresh, 1)) =~ "Decision: continue with the native tool."
    assert Enum.count(fresh, &(text(&1) == "new driving query")) == 1
    refute Enum.any?(fresh, &(text(&1) == "first"))
    assert {:ok, during_swap} = ai(pid)
    assert during_swap.last_input_tokens == nil
    assert during_swap.last_handoff.before_tokens >= 4_400
    answer(successor, "done", %{input_tokens: 120})
    assert {:ok, "done"} = Task.await(next, 5_000)
  end

  test "under-threshold reported usage starts the new ordinary request", ctx do
    pid = start_server(ctx, Agent)
    first = ask(pid, "first", options())
    assert_receive {:provider_request, provider, "offline", _, [_]}, 5_000
    answer(provider, "first answer", %{input_tokens: 100})
    assert {:ok, "first answer"} = Task.await(first, 5_000)
    second = ask(pid, "second", options())
    assert_receive {:provider_request, provider, "offline", history, [_]}, 5_000
    assert text(List.last(history)) == "second"
    refute Enum.any?(history, &(text(&1) =~ "ONLY thing your successor receives"))
    answer(provider, "ordinary")
    assert {:ok, "ordinary"} = Task.await(second, 5_000)
  end

  test "model, client, provider options and real prepared-tool changes invalidate the count",
       ctx do
    variants = [
      {"model", [model: "other"]},
      {"client", [client: OtherClient]},
      {"provider options", [llm_opts: [temperature: 0.7]]},
      {"prepared tools", [tools: [:test_multiply]]}
    ]

    for {label, override} <- variants do
      pid = start_server(ctx, Agent)
      first = ask(pid, "first", options())
      assert_receive {:provider_request, provider, "offline", _, [_]}, 5_000
      answer(provider, "first answer", %{input_tokens: 4_400})
      assert {:ok, "first answer"} = Task.await(first, 5_000)
      assert {:ok, %{last_input_tokens: 4_400}} = ai(pid)
      changed = Keyword.merge(options(), override)
      second = ask(pid, "changed " <> label, changed)
      assert_receive {:provider_request, provider, _, history, [_]}, 5_000
      assert text(List.last(history)) == "changed " <> label
      assert {:ok, %{last_input_tokens: nil}} = ai(pid)
      answer(provider, "changed")
      assert {:ok, "changed"} = Task.await(second, 5_000)
    end
  end

  test "public context replacement invalidates previous pressure", ctx do
    pid = start_server(ctx, Agent)
    first = ask(pid, "first", options())
    assert_receive {:provider_request, provider, "offline", _, [_]}, 5_000
    answer(provider, "first answer", %{input_tokens: 4_400})
    assert {:ok, "first answer"} = Task.await(first, 5_000)

    assert %{status: :processed} =
             Agent
             |> Ash.ActionInput.for_action(
               :replace_context,
               %{agent: pid, messages: [ReqLLM.Context.user("replacement")]}
             )
             |> Ash.run_action!()

    assert {:ok, %{last_input_tokens: nil, last_input_shape: nil}} = ai(pid)
    second = ask(pid, "after replacement", options())
    assert_receive {:provider_request, provider, "offline", history, [_]}, 5_000
    assert text(List.last(history)) == "after replacement"
    answer(provider, "ordinary")
    assert {:ok, "ordinary"} = Task.await(second, 5_000)
  end

  test "missing and malformed provider input counts leave the estimate in charge", ctx do
    for usage <- [%{}, %{input_tokens: "4,400"}, %{input_tokens: -1}] do
      pid = start_server(ctx, Agent)
      first = ask(pid, "first", options())
      assert_receive {:provider_request, provider, "offline", _, [_]}, 5_000
      answer(provider, "first answer", usage)
      assert {:ok, "first answer"} = Task.await(first, 5_000)
      assert {:ok, %{last_input_tokens: nil, estimated_tokens: estimate}} = ai(pid)
      assert estimate < 4_000
      second = ask(pid, "second", options())
      assert_receive {:provider_request, provider, "offline", history, [_]}, 5_000
      assert text(List.last(history)) == "second"
      answer(provider, "ordinary")
      assert {:ok, "ordinary"} = Task.await(second, 5_000)
    end
  end

  test "same-name prepared schema, description and provider options invalidate reported usage",
       ctx do
    for variant <- [:schema, :description, :provider_options] do
      pid = start_server(ctx, Agent)
      first = ask(pid, "first", prepared_options(self(), :base))
      assert_receive {:prepared_tool, :base, first_callback, _}, 5_000
      assert_receive {:provider_request, provider, "offline", _, [original]}, 5_000
      assert original.name == "pressure_probe"
      answer(provider, "first answer", %{input_tokens: 4_400})
      assert {:ok, "first answer"} = Task.await(first, 5_000)

      second = ask(pid, "changed", prepared_options(self(), variant))
      assert_receive {:prepared_tool, ^variant, second_callback, _}, 5_000
      assert first_callback != second_callback
      assert_receive {:provider_request, provider, "offline", history, [changed]}, 5_000
      assert changed.name == original.name
      assert text(List.last(history)) == "changed"
      assert {:ok, %{last_input_tokens: nil}} = ai(pid)

      case variant do
        :schema -> refute changed.parameter_schema == original.parameter_schema
        :description -> refute changed.description == original.description
        :provider_options -> refute changed.provider_options == original.provider_options
      end

      answer(provider, "ordinary")
      assert {:ok, "ordinary"} = Task.await(second, 5_000)
    end
  end

  test "fresh callback with identical prepared description retains the provider floor", ctx do
    pid = start_server(ctx, Agent)
    first = ask(pid, "first", prepared_options(self(), :base))
    assert_receive {:prepared_tool, :base, first_callback, _}, 5_000
    assert_receive {:provider_request, provider, "offline", _, [original]}, 5_000
    answer(provider, "first answer", %{input_tokens: 4_400})
    assert {:ok, "first answer"} = Task.await(first, 5_000)

    second = ask(pid, "new query", prepared_options(self(), :callback))
    assert_receive {:prepared_tool, :callback, second_callback, _}, 5_000
    assert first_callback != second_callback
    assert_receive {:provider_request, writer, "offline", handoff, []}, 5_000
    assert text(List.last(handoff)) =~ "ONLY thing your successor receives"
    answer(writer, "Continue from the decision.")
    assert_receive {:provider_request, successor, "offline", fresh, [rebuilt]}, 5_000

    assert Map.take(rebuilt, [:name, :description, :parameter_schema, :strict, :provider_options]) ==
             Map.take(original, [
               :name,
               :description,
               :parameter_schema,
               :strict,
               :provider_options
             ])

    assert Enum.count(fresh, &(text(&1) == "new query")) == 1
    answer(successor, "done")
    assert {:ok, "done"} = Task.await(second, 5_000)
  end

  test "setup and handoff queued text follow the driving query once and in order", ctx do
    pid = start_server(ctx, Agent)
    first = ask(pid, "first", prepared_options(self(), :base))
    assert_receive {:prepared_tool, :base, _, _}, 5_000
    assert_receive {:provider_request, provider, "offline", _, [_]}, 5_000
    answer(provider, "first answer", %{input_tokens: 4_400})
    assert {:ok, "first answer"} = Task.await(first, 5_000)

    second = ask(pid, "driving query", prepared_options(self(), :base, %{hold: true}))
    assert_receive {:prepared_tool, :base, _, preparation}, 5_000
    assert {:ok, :queued} = Aikido.AI.queue_message(pid, "queued during setup")
    send(preparation, :release)
    assert_receive {:provider_request, writer, "offline", _, []}, 5_000
    assert {:ok, :queued} = Aikido.AI.queue_message(pid, "queued during handoff")
    answer(writer, "Carry the decision.")
    assert_receive {:provider_request, successor, "offline", fresh, [_]}, 5_000
    assert Enum.map(fresh, & &1.role) == [:system, :user, :user, :user, :user]

    assert Enum.map(Enum.drop(fresh, 2), &text/1) ==
             ["driving query", "queued during setup", "queued during handoff"]

    answer(successor, "done")
    assert {:ok, "done"} = Task.await(second, 5_000)
  end

  test "failed first-turn handoff keeps the original context and does not enqueue its query again",
       ctx do
    pid = start_server(ctx, Agent)
    first = ask(pid, "first", options())
    assert_receive {:provider_request, provider, "offline", _, [_]}, 5_000
    answer(provider, "first answer", %{input_tokens: 4_400})
    assert {:ok, "first answer"} = Task.await(first, 5_000)

    second = ask(pid, "failed driving query", options())
    assert_receive {:provider_request, writer, "offline", _, []}, 5_000
    send(writer, {:provider_answer, {:error, :provider_unavailable}})
    assert {:error, {:context_handoff_failed, :provider_unavailable}} = Task.await(second, 5_000)
    assert {:ok, failed} = ai(pid)
    assert failed.status == :failed
    assert Enum.count(failed.context.messages, &(text(&1) == "failed driving query")) == 1
    assert failed.queued_messages == []
  end

  test "streaming-mode change invalidates the old nonstreaming provider count", ctx do
    pid = start_server(ctx, Agent)
    first = ask(pid, "first", options())
    assert_receive {:provider_request, provider, "offline", _, [_]}, 5_000
    answer(provider, "first answer", %{input_tokens: 4_400})
    assert {:ok, "first answer"} = Task.await(first, 5_000)

    streaming =
      Keyword.put(options(), :options, %{
        context_max_tokens: 5_000,
        handoff_buffer_tokens: 1_000,
        streaming: true
      })

    second = ask(pid, "stream next", streaming)
    assert_receive {:provider_stream_request, stream, "offline", history, [_]}, 5_000
    assert text(List.last(history)) == "stream next"
    assert {:ok, %{last_input_tokens: nil}} = ai(pid)
    send(stream, {:provider_stream_answer, "streamed"})
    assert {:ok, "streamed"} = Task.await(second, 5_000)
  end

  test "Durable public stop and restart invalidate persisted provider pressure", ctx do
    id = unique_id()
    pid = start_server(ctx, Agent, id: id)
    first = ask(pid, "first", options())
    assert_receive {:provider_request, provider, "offline", _, [_]}, 5_000
    answer(provider, "first answer", %{input_tokens: 4_400})
    assert {:ok, "first answer"} = Task.await(first, 5_000)
    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(ctx.aikido), pid)
    assert {:ok, restored} = start_test_agent(ctx, Agent, id: id)
    assert {:ok, %{last_input_tokens: nil, last_input_shape: nil}} = ai(restored)
    second = ask(restored, "after restart", options())
    assert_receive {:provider_request, provider, "offline", history, [_]}, 5_000
    assert text(List.last(history)) == "after restart"
    answer(provider, "ordinary")
    assert {:ok, "ordinary"} = Task.await(second, 5_000)
  end

  defp prepared_options(observer, variant, extra_metadata \\ %{}) do
    options()
    |> Keyword.put(:tools, [])
    |> Keyword.put(:options, %{
      context_max_tokens: 5_000,
      handoff_buffer_tokens: 1_000,
      tool_preparation: {Aikido.ProviderPressureTest.Preparation, :prepare}
    })
    |> Keyword.put(:metadata, Map.merge(%{observer: observer, variant: variant}, extra_metadata))
  end

  defp ask(pid, query, options) do
    observer = self()
    llm_opts = Keyword.put(options[:llm_opts] || [], :observer, observer)
    options = Keyword.put(options, :llm_opts, llm_opts)
    Task.async(fn -> Aikido.AI.ask_sync(pid, query, options) end)
  end

  defp options do
    [
      model: "offline",
      client: Client,
      tools: [:test_add],
      system_prompt: "Keep the standing procedure.",
      llm_opts: [],
      timeout: 10_000,
      options: %{context_max_tokens: 5_000, handoff_buffer_tokens: 1_000}
    ]
  end

  defp answer(provider, text, usage \\ %{}) do
    send(
      provider,
      {:provider_answer,
       {:ok,
        %ReqLLM.Response{
          id: Ash.UUIDv7.generate(),
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant(text, tool_calls: []),
          usage: usage,
          finish_reason: :stop
        }}}
    )
  end

  defp ai(pid), do: Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})
  defp text(message), do: Enum.map_join(message.content, &(&1.text || ""))
end
