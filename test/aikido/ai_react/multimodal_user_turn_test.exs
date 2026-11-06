defmodule Aikido.AiReact.MultimodalUserTurnTest do
  use AikidoTest.Case, async: true

  alias Aikido.AI.Test.ResponseFixtures
  alias AikidoTest.MultimodalUserTurn.{Client, Domain}
  alias ReqLLM.Message.ContentPart

  @moduletag aikido_instance: AikidoTest.MultimodalUserTurn.Instance

  setup do
    scope = [actor: %{id: "owner"}, tenant: "workspace"]

    assert {:ok, subject} =
             Domain.subject_start(
               %{
                 model: "offline",
                 client: Client,
                 tools: [],
                 llm_opts: [observer: self()],
                 options: %{handoff: false, completion: :todos, todo_continuation: :wait}
               },
               scope
             )

    %{subject: subject, scope: scope}
  end

  @tag story: "US-AIKIDO-MULTIMODAL-01"
  test "generated ask submits text and ordered native content in one user turn", ctx do
    parts = parts()
    authored = "  Inspect these\n"

    assert {:ok, _receipt} =
             Domain.subject_ask(
               ctx.subject,
               %{query: authored, content_parts: parts},
               ctx.scope
             )

    assert_receive {:multimodal_request, worker, messages}, 5_000
    assert [%ReqLLM.Message{role: :user, content: content}] = messages
    assert content == [ContentPart.text(authored) | parts]
    assert {:ok, %{context: %ReqLLM.Context{messages: [stored]}}} = ai(ctx.subject)
    assert stored.content == [ContentPart.text(authored) | parts]
    finish(worker, ctx.subject)
  end

  @tag story: "US-AIKIDO-MULTIMODAL-05"
  test "ask_sync forwards content parts without replacing native history", ctx do
    parts = parts()
    authored = "  Inspect these\n"

    task =
      Task.async(fn ->
        Aikido.AI.ask_sync(
          ctx.subject.pid,
          authored,
          Keyword.put(ctx.scope, :content_parts, parts)
        )
      end)

    assert_receive {:multimodal_request, worker, messages}, 5_000
    assert [%{role: :user, content: content}] = messages
    assert content == [ContentPart.text(authored) | parts]
    send(worker, {:answer, ResponseFixtures.final_answer_response("done")})
    assert {:ok, "done"} = Task.await(task, 5_000)
  end

  @tag story: "US-AIKIDO-MULTIMODAL-02"
  test "active message and delivery retain one ordered queue and delivery deduplication", ctx do
    text_only = "  Text only\n"
    queued = "  Queued image\n"
    delivered = "  Delivered image\n"
    assert {:ok, _} = Domain.subject_ask(ctx.subject, %{query: "Start"}, ctx.scope)
    assert_receive {:multimodal_request, first, _}, 5_000
    assert {:ok, :queued} = Aikido.AI.queue_message(ctx.subject.pid, text_only, ctx.scope)

    assert {:ok, :queued} =
             Aikido.AI.queue_message(
               ctx.subject.pid,
               queued,
               Keyword.put(ctx.scope, :content_parts, parts())
             )

    delivery = %{text: delivered, content_parts: parts(), request_id: "image-delivery"}
    assert {:ok, _} = Domain.subject_deliver(ctx.subject, delivery, ctx.scope)
    assert {:ok, _} = Domain.subject_deliver(ctx.subject, delivery, ctx.scope)
    send(first, {:answer, ResponseFixtures.final_answer_response("first answer")})

    assert_receive {:multimodal_request, second, messages}, 5_000

    expected = [
      [ContentPart.text("Start")],
      [ContentPart.text(text_only)],
      [ContentPart.text(queued) | parts()],
      [ContentPart.text(delivered) | parts()]
    ]

    assert Enum.map(Enum.filter(messages, &(&1.role == :user)), & &1.content) == expected
    assert {:ok, %{context: %ReqLLM.Context{messages: stored}}} = ai(ctx.subject)
    assert Enum.map(Enum.filter(stored, &(&1.role == :user)), & &1.content) == expected

    finish(second, ctx.subject)
  end

  @tag story: "US-AIKIDO-MULTIMODAL-03"
  test "content never replaces the active caller or tenant", ctx do
    assert {:ok, _} = Domain.subject_ask(ctx.subject, %{query: "Start"}, ctx.scope)
    assert_receive {:multimodal_request, worker, _}, 5_000

    for scope <- [
          [actor: %{id: "other"}, tenant: "workspace"],
          [actor: %{id: "owner"}, tenant: "other-workspace"]
        ] do
      assert {:error, _} =
               Domain.subject_deliver(
                 ctx.subject,
                 %{text: "Rejected", content_parts: parts(), request_id: "rejected"},
                 scope
               )
    end

    assert {:ok, %{queued_messages: [], accepted_delivery_ids: []}} = ai(ctx.subject)
    finish(worker, ctx.subject)
  end

  for {action, story} <- [
        message: "US-AIKIDO-MULTIMODAL-06",
        deliver: "US-AIKIDO-MULTIMODAL-07"
      ] do
    @tag story: story
    test "#{action} resumes a waiting run with all parts in the same user turn", ctx do
      authored = "  Evidence\n"

      assert {:ok, _} =
               Domain.subject_todo_add(
                 ctx.subject,
                 %{id: "pending", text: "Wait for evidence", blocking?: true},
                 ctx.scope
               )

      assert {:ok, _} = Domain.subject_ask(ctx.subject, %{query: "Start"}, ctx.scope)
      assert_receive {:multimodal_request, first, _}, 5_000
      settle(first, ctx.subject, :waiting)

      result =
        case unquote(action) do
          :message ->
            Aikido.AI.queue_message(
              ctx.subject.pid,
              authored,
              Keyword.put(ctx.scope, :content_parts, parts())
            )

          :deliver ->
            Domain.subject_deliver(
              ctx.subject,
              %{text: authored, content_parts: parts(), request_id: "evidence"},
              ctx.scope
            )
        end

      assert {:ok, _} = result

      assert_receive {:multimodal_request, second, messages}, 5_000
      assert List.last(messages).content == [ContentPart.text(authored) | parts()]
      settle(second, ctx.subject, :waiting)
    end
  end

  @tag story: "US-AIKIDO-MULTIMODAL-04"
  test "a real durable stop and restart retains multipart history and pending mixed input", ctx do
    assert {:ok, _} =
             Domain.subject_ask(
               ctx.subject,
               %{query: "Original", content_parts: parts()},
               ctx.scope
             )

    assert_receive {:multimodal_request, first, _}, 5_000
    finish(first, ctx.subject)
    assert {:ok, :queued} = Aikido.AI.queue_message(ctx.subject.pid, "Retained text", ctx.scope)

    assert {:ok, :queued} =
             Aikido.AI.queue_message(
               ctx.subject.pid,
               "Retained image",
               Keyword.put(ctx.scope, :content_parts, parts())
             )

    monitor = Process.monitor(ctx.subject.pid)
    assert {:ok, _} = Domain.subject_stop(ctx.subject, %{}, ctx.scope)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert {:ok, restored} = Domain.subject_start(%{id: ctx.subject.id}, ctx.scope)
    assert restored.id == ctx.subject.id
    refute restored.pid == ctx.subject.pid
    assert {:ok, _} = Domain.subject_ask(restored, %{query: "Continue"}, ctx.scope)
    assert_receive {:multimodal_request, second, messages}, 5_000

    assert Enum.map(Enum.filter(messages, &(&1.role == :user)), & &1.content) == [
             [ContentPart.text("Original") | parts()],
             [ContentPart.text("Retained text")],
             [ContentPart.text("Retained image") | parts()],
             [ContentPart.text("Continue")]
           ]

    finish(second, restored)
  end

  @tag story: "US-AIKIDO-MULTIMODAL-08"
  test "native argument casting rejects untyped content maps", ctx do
    assert {:error, _} =
             Domain.subject_ask(
               ctx.subject,
               %{query: "Rejected", content_parts: [%{type: :image, data: "fake"}]},
               ctx.scope
             )

    assert {:ok, %{status: :idle}} = ai(ctx.subject)
    refute_received {:multimodal_request, _, _}
  end

  @tag story: "US-AIKIDO-MULTIMODAL-15"
  test "blank authored text stays invalid through generated and convenience input", ctx do
    for blank <- ["", " \t\n "] do
      assert {:error, _} =
               Domain.subject_ask(
                 ctx.subject,
                 %{query: blank, content_parts: parts()},
                 ctx.scope
               )

      assert {:error, _} =
               Domain.subject_message(
                 ctx.subject,
                 %{text: blank, content_parts: parts()},
                 ctx.scope
               )

      assert {:error, _} =
               Domain.subject_deliver(
                 ctx.subject,
                 %{text: blank, content_parts: parts(), request_id: "blank-delivery"},
                 ctx.scope
               )

      options = Keyword.put(ctx.scope, :content_parts, parts())
      assert {:error, _} = Aikido.AI.ask(ctx.subject.pid, blank, options)
      assert {:error, _} = Aikido.AI.queue_message(ctx.subject.pid, blank, options)
    end

    assert {:ok, %{status: :idle, queued_messages: [], accepted_delivery_ids: []}} =
             ai(ctx.subject)

    refute_received {:multimodal_request, _, _}
  end

  @tag story: "US-AIKIDO-MULTIMODAL-09"
  test "retained native string-array storage loads without discarding pending text" do
    retained = ["Previous input", "第二条", "🦊"]
    assert {:ok, stored} = Ash.Type.dump_to_embedded({:array, :string}, retained)

    for name <- [:queued_messages, :opening_messages] do
      attribute = Ash.Resource.Info.attribute(Aikido.AiReact.Slice, name)

      assert {:ok, ^retained} =
               Ash.Type.cast_from_embedded(attribute.type, stored, attribute.constraints)
    end
  end

  @tag story: "US-AIKIDO-MULTIMODAL-10"
  test "native queue type dumping retains a mixed ordered message list" do
    messages = ["Retained text", [ContentPart.text("Retained image") | parts()]]

    for name <- [:queued_messages, :opening_messages] do
      attribute = Ash.Resource.Info.attribute(Aikido.AiReact.Slice, name)

      assert {:ok, stored} =
               Ash.Type.dump_to_embedded(attribute.type, messages, attribute.constraints)

      assert {:ok, ^messages} =
               Ash.Type.cast_from_embedded(attribute.type, stored, attribute.constraints)
    end
  end

  @tag story: "US-AIKIDO-MULTIMODAL-11"
  test "corrupt external-term queue storage fails instead of becoming user text" do
    # A list with a declared element but no encoded element or list terminator.
    corrupt = <<131, 108, 0, 0, 0, 1>>

    for name <- [:queued_messages, :opening_messages] do
      attribute = Ash.Resource.Info.attribute(Aikido.AiReact.Slice, name)

      assert_raise ArgumentError, fn ->
        Ash.Type.cast_from_embedded(attribute.type, [corrupt], attribute.constraints)
      end
    end
  end

  @tag story: "US-AIKIDO-MULTIMODAL-12"
  test "legacy binary text beginning with byte 131 is not accepted as retained UTF-8 text" do
    unsupported = <<131, "legacy text">>
    assert {:ok, stored} = Ash.Type.dump_to_embedded({:array, :string}, [unsupported])

    for name <- [:queued_messages, :opening_messages] do
      attribute = Ash.Resource.Info.attribute(Aikido.AiReact.Slice, name)

      assert_raise ArgumentError, fn ->
        Ash.Type.cast_from_embedded(attribute.type, stored, attribute.constraints)
      end
    end
  end

  @tag story: "US-AIKIDO-MULTIMODAL-13"
  test "sensitive queues stay readable to an authorized caller but are hidden by native diagnostics",
       ctx do
    content = [ContentPart.text("Queued image") | parts()]

    assert {:ok, :queued} =
             Aikido.AI.queue_message(
               ctx.subject.pid,
               "Queued image",
               Keyword.put(ctx.scope, :content_parts, parts())
             )

    assert {:ok, %{ai: slice}} =
             Domain.subject_inspect(ctx.subject, %{fields: [:ai]}, ctx.scope)

    assert slice.queued_messages == [content]
    assert is_struct(slice, Aikido.AiReact.Slice)

    projected =
      Aikido.Inspector.History.project_agent_state(
        %{ai: slice},
        AikidoTest.MultimodalUserTurn.Agent
      )

    assert projected["ai"]["queued_messages"] == "[redacted]"
    assert projected["ai"]["opening_messages"] == "[redacted]"
    diagnostic = inspect(slice, limit: :infinity, printable_limit: :infinity)
    refute diagnostic =~ "fixture-image-bytes"
    refute diagnostic =~ "fixture-file-bytes"
    refute diagnostic =~ "Queued image"
    assert {:ok, %{queued_messages: [^content]}} = ai(ctx.subject)
  end

  @tag story: "US-AIKIDO-MULTIMODAL-14"
  test "the existing diagnostic projection redacts populated opening and queued fields" do
    content = [ContentPart.text("Private input") | parts()]

    slice =
      Ash.create!(Aikido.AiReact.Slice, %{
        opening_messages: [content],
        queued_messages: [content]
      })

    for value <- [slice, Map.from_struct(slice)] do
      projected =
        Aikido.Inspector.History.project_agent_state(
          %{ai: value},
          AikidoTest.MultimodalUserTurn.Agent
        )

      assert projected["ai"]["queued_messages"] == "[redacted]"
      assert projected["ai"]["opening_messages"] == "[redacted]"
    end

    diagnostic = inspect(slice, limit: :infinity, printable_limit: :infinity)
    refute diagnostic =~ "fixture-image-bytes"
    refute diagnostic =~ "fixture-file-bytes"
    refute diagnostic =~ "Private input"
    assert slice.opening_messages == [content]
    assert slice.queued_messages == [content]
  end

  defp parts do
    [
      ContentPart.image("fixture-image-bytes", "image/png"),
      ContentPart.file("fixture-file-bytes", "notes.txt", "text/plain")
    ]
  end

  defp ai(subject), do: Aikido.AgentServer.state(subject.pid, &{:ok, &1.agent.state.ai})

  defp finish(worker, subject), do: settle(worker, subject, :completed)

  defp settle(worker, subject, status) do
    assert {:ok, ^status} =
             Aikido.AgentServer.call_until(
               subject.pid,
               fn ->
                 send(worker, {:answer, ResponseFixtures.final_answer_response("done")})
                 :ok
               end,
               "ai.react.**",
               fn runtime ->
                 if runtime.agent.state.ai.status == status,
                   do: {:ok, status},
                   else: :skip
               end
             )
  end
end
