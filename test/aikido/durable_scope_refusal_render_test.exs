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
      denial_facts: "role=coder definition=db:5f8e2b1e-1111-4222-8333-444455556666@7 request=req-123",
      internal: "never-render-this-sentinel"
    )

    assert {:error, reason} = Domain.recorder_start(%{id: unique_id("refusal-facts")})
    refusal = scope_refusal(reason)
    assert %ScopeRefusal{operation: :prepare, reason: :autonomous_worker_review_required} = refusal

    assert refusal.vars[:request_id] == "req-123"
    assert refusal.vars[:denial_facts] =~ "role=coder"
    refute Keyword.has_key?(refusal.vars, :internal)

    rendered = Exception.message(refusal)
    assert rendered =~ "autonomous_worker_review_required"
    assert rendered =~ "role=coder"
    assert rendered =~ "request=req-123"
    refute rendered =~ "never-render-this-sentinel"
  end

  test "a refusal without facts keeps the historical message unchanged" do
    Authority.deny([])

    assert {:error, reason} = Domain.recorder_start(%{id: unique_id("refusal-plain")})
    refusal = scope_refusal(reason)
    assert %ScopeRefusal{operation: :prepare, reason: :autonomous_worker_review_required} = refusal
    refute Keyword.get(refusal.vars || [], :denial_facts)

    assert Exception.message(refusal) ==
             "Durable scope prepare rejected: autonomous_worker_review_required"
  end

  defp scope_refusal(%ScopeRefusal{} = refusal), do: refusal
  defp scope_refusal(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &scope_refusal/1)

  defp scope_refusal(_other), do: nil
end
