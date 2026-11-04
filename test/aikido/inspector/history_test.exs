defmodule AikidoTest.Inspector.HistoryTest do
  use ExUnit.Case, async: true
  alias Aikido.Inspector.History

  test "known credential and runtime keys are redacted without name heuristics" do
    private = [
      "apiKey",
      "API_KEY",
      "authorization",
      "password",
      "secret",
      "access_token",
      "refresh_token",
      "execution_credential",
      "actor",
      "tenant",
      "tracer_context"
    ]

    public = [
      "api-key",
      "api key",
      "api.key",
      "apiXkey",
      "providerApiKeyOverride",
      "deviceSecret",
      "PASSWORD_HINT",
      "AUTHORIZATION_HEADER",
      "CredentialCache",
      "token",
      "TOKEN_id",
      "id_token",
      "id_token_kind",
      "apiXXkey",
      "api\nkey",
      "tokenizer",
      "notoken",
      "id-token",
      "credibility",
      "api",
      "key",
      "model",
      "input_tokens",
      "output_tokens",
      "estimated_tokens",
      "ＡＰＩkey",
      "İtoken",
      "foo_ΤΟΚΕΝ",
      "count",
      "status",
      "numbers"
    ]

    for name <- private do
      assert History.project_state(%{name => "private value"}) == %{name => "[redacted]"}
    end

    for name <- public do
      assert History.project_state(%{name => "public value"}) == %{name => "public value"}
    end
  end

  test "projection preserves empty maps and bounds nested values without losing the tree" do
    projected =
      History.project_state(%{
        settings: %{},
        nested: %{visible: "retained", secret: "private"},
        samples: Enum.to_list(1..100)
      })

    assert projected["settings"] == %{}
    assert projected["nested"] == %{"visible" => "retained", "secret" => "[redacted]"}
    assert projected["samples"] == Enum.to_list(1..30) ++ ["[list truncated]"]
  end

  test "history displays a late entry in sequence order" do
    snapshot = %{id: "counter", inspected_state: %{}}

    history = History.record(%{History.new() | sequence: 2}, snapshot, [], %{}, nil)
    history = History.record(%{history | sequence: 1}, snapshot, [], %{}, nil)

    assert Enum.map(history.entries, & &1.sequence) == [3, 2]
  end

  test "JSON bounds count escaped and multibyte content without flattening values" do
    value = %{"nested" => [%{"text" => String.duplicate("雪\n\"", 300)}]}
    bounded = Aikido.Inspector.History.Bounds.limit(value, 512)

    assert is_map(bounded)
    assert byte_size(Jason.encode!(bounded)) <= 512
    assert Aikido.Inspector.History.Bounds.limit(value, 32_768) == value
  end
end
