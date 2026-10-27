defmodule AikidoTest.Inspector.HistoryTest do
  use ExUnit.Case, async: true
  alias Aikido.Inspector.History

  test "credential-name redaction preserves case, separators and token boundaries" do
    private = [
      "apiKey",
      "API_KEY",
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
      "actor",
      "tenant",
      "tracer_context"
    ]

    public = [
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
end
