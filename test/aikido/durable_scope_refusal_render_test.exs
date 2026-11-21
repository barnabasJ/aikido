defmodule Aikido.DurableScopeRefusalRenderTest do
  @moduledoc """
  The real native start sanitization for scope refusals: the public refusal
  retains the application-authored bounded denial facts and request reference
  and still drops unknown internal vars, the rendered lead/tool message
  carries those facts, and a refusal without facts keeps the historical
  message unchanged.
  """
  use AikidoTest.Case, async: false

  import AikidoTest.Case, only: [unique_id: 1]

  alias Aikido.Durable.ScopeAdapter.Error, as: ScopeRefusal
  alias Aikido.DurableScopeRefusalRenderTest.Authority
  alias Aikido.DurableScopeRefusalRenderTest.Domain

  @moduletag aikido_instance: Aikido.DurableScopeRefusalRenderTest.Instance,
             aikido_scope_adapter: Aikido.DurableScopeRefusalRenderTest.Authority

  setup do
    on_exit(fn -> :persistent_term.erase({Authority, :prepare}) end)
    :ok
  end

  test "start retains bounded denial facts and request id, drops unknown internal vars" do
    Authority.deny(
      request_id: "req-123",
      denial_facts:
        "role=coder definition=db:5f8e2b1e-1111-4222-8333-444455556666@7 request=req-123",
      internal: "never-render-this-sentinel"
    )

    assert {:error, reason} = Domain.recorder_start(%{id: unique_id("refusal-facts")})
    refusal = scope_refusal(reason)

    assert %ScopeRefusal{operation: :prepare, reason: :autonomous_worker_review_required} =
             refusal

    assert refusal.vars[:request_id] == "req-123"
    assert refusal.vars[:denial_facts] =~ "role=coder"
    refute Keyword.has_key?(refusal.vars, :internal)

    rendered = Exception.message(refusal)
    assert rendered =~ "autonomous_worker_review_required"
    assert rendered =~ "role=coder"
    assert rendered =~ "request=req-123"
    refute rendered =~ "never-render-this-sentinel"
    assert Exception.message(reason) =~ "role=coder"
    refute Exception.message(reason) =~ "never-render-this-sentinel"
    refute inspect(reason, limit: :infinity) =~ "never-render-this-sentinel"
  end

  test "absent or empty facts keep the base message unchanged" do
    for vars <- [[], [denial_facts: ""]] do
      Authority.deny(vars)

      assert {:error, reason} = Domain.recorder_start(%{id: unique_id("refusal-plain")})
      refusal = scope_refusal(reason)

      assert %ScopeRefusal{operation: :prepare, reason: :autonomous_worker_review_required} =
               refusal

      assert Keyword.get(refusal.vars || [], :denial_facts) in [nil, ""]

      assert Exception.message(%{refusal | bread_crumbs: []}) ==
               "Durable scope prepare rejected: autonomous_worker_review_required"
    end
  end

  test "native start preserves plural request ids and application-typed denial facts" do
    Authority.deny(
      [
        request_id: "req-one",
        request_ids: ["req-one", "req-two"],
        denial_facts: "Two approvals are required.",
        denial: %{
          subject: "subject-seven",
          permissions: ["documents.read", "documents.write"],
          internal: "private-nested-marker"
        },
        internal: "private-top-level-marker"
      ],
      Aikido.DurableScopeRefusalRenderTest.Denial
    )

    assert {:error, reason} = Domain.recorder_start(%{id: unique_id("plural-denial")})
    refusal = scope_refusal(reason)
    assert refusal.vars[:request_id] == "req-one"
    assert refusal.vars[:request_ids] == ["req-one", "req-two"]

    assert refusal.vars[:denial] == %{
             subject: "subject-seven",
             permissions: ["documents.read", "documents.write"]
           }

    assert Exception.message(reason) =~ "Two approvals are required."
    assert refusal.denial_type == nil
    refute inspect(reason, limit: :infinity) =~ "private-"
  end

  test "untyped structured denial is omitted while bounded plural ids remain public" do
    Authority.deny(
      request_ids: ["req-one", "req-two"],
      denial: %{private: "private-untyped-marker"},
      internal: "private-top-level-marker"
    )

    assert {:error, reason} = Domain.recorder_start(%{id: unique_id("untyped-denial")})
    refusal = scope_refusal(reason)
    assert refusal.vars[:request_ids] == ["req-one", "req-two"]
    refute Keyword.has_key?(refusal.vars, :denial)
    refute inspect(reason, limit: :infinity) =~ "private-"
  end

  test "invalid or oversized public values preserve the refusal without leaking vars" do
    for vars <- [
          [request_ids: List.duplicate("request", 65)],
          [request_ids: [String.duplicate("r", 257)]],
          [request_id: String.duplicate("r", 257)],
          [denial_facts: String.duplicate("é", 32_769)],
          [denial: %{subject: String.duplicate("s", 129)}],
          [denial: %{permissions: List.duplicate("documents.read", 9)}],
          [denial: %{permissions: [%{private: "private-invalid-marker"}]}]
        ] do
      Authority.deny(
        Keyword.put(vars, :internal, "private-internal-marker"),
        Aikido.DurableScopeRefusalRenderTest.Denial
      )

      assert {:error, reason} = Domain.recorder_start(%{id: unique_id("invalid-public-denial")})

      assert %ScopeRefusal{operation: :prepare, reason: :autonomous_worker_review_required} =
               refusal = scope_refusal(reason)

      assert refusal.vars == []
      refute inspect(reason, limit: :infinity) =~ "private-"
    end
  end

  test "native Ash byte and count bounds include their exact public limits" do
    id = String.duplicate("r", 256)
    ids = List.duplicate(id, 64)
    facts = String.duplicate("é", 32_768)

    denial = %{
      subject: String.duplicate("s", 128),
      permissions: List.duplicate(String.duplicate("p", 128), 8)
    }

    Authority.deny(
      [request_id: id, request_ids: ids, denial_facts: facts, denial: denial],
      Aikido.DurableScopeRefusalRenderTest.Denial
    )

    assert {:error, reason} = Domain.recorder_start(%{id: unique_id("public-denial-limits")})
    refusal = scope_refusal(reason)
    assert refusal.vars[:request_id] == id
    assert refusal.vars[:request_ids] == ids
    assert refusal.vars[:denial_facts] == facts
    assert refusal.vars[:denial] == denial
  end

  defp scope_refusal(%ScopeRefusal{} = refusal), do: refusal

  defp scope_refusal(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &scope_refusal/1)

  defp scope_refusal(_other), do: nil
end
