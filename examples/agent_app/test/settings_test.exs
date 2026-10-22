defmodule AgentExamples.SettingsTest do
  use ExUnit.Case, async: false
  alias AgentExamples.{Playground, Settings}
  import Phoenix.ConnTest
  @endpoint AgentExamplesWeb.Endpoint

  test "AshCloak stores ciphertext and decrypts only when explicitly loaded" do
    owner = Ash.UUIDv7.generate()
    key = "sqlite-secret-#{owner}"

    assert {:ok, _} =
             Playground.configure_provider(owner, %{
               "mode" => "live",
               "provider" => "zai_coder",
               "model" => "glm-5.3",
               "api_key" => key
             })

    credential = Ash.get!(Settings.Credential, %{owner: owner, provider: "zai"})
    assert %Ash.NotLoaded{} = credential.api_key
    refute inspect(credential) =~ key
    assert Ash.load!(credential, :api_key).api_key == key

    %{rows: [[ciphertext]]} =
      Settings.Repo.query!("SELECT encrypted_api_key FROM provider_credentials WHERE owner = ?", [
        owner
      ])

    assert is_binary(ciphertext)
    refute ciphertext == key
    assert :binary.match(ciphertext, key) == :nomatch
    refute Map.has_key?(Playground.provider_settings(owner), :api_key)
  end

  test "settings and credentials survive restarting their repo, vault and playground" do
    owner = Ash.UUIDv7.generate()
    key = "restart-secret-#{owner}"

    assert {:ok, settings} =
             Playground.configure_provider(owner, %{
               "mode" => "live",
               "provider" => "zai_coder",
               "model" => "glm-5.3",
               "api_key" => key
             })

    for child <- [Playground, Settings.Repo, Settings.Vault] do
      :ok = Supervisor.terminate_child(AgentExamples.Supervisor, child)
    end

    for child <- [Settings.Vault, Settings.Repo, Playground] do
      assert {:ok, _} = Supervisor.restart_child(AgentExamples.Supervisor, child)
    end

    assert Playground.provider_settings(owner) == settings
    assert Playground.provider_key(owner, :zai_coding_plan) == {:ok, key}

    assert Playground.provider_key(Ash.UUIDv7.generate(), :zai_coder) ==
             {:error, "Configure an API key in the example app's provider form."}

    directory = Application.fetch_env!(:agent_examples, :settings_directory)
    assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(Path.join(directory, "credential.key")).mode, 0o777) == 0o600
  end

  test "a failed preference save rolls back the accompanying credential" do
    owner = Ash.UUIDv7.generate()

    assert {:error, _} =
             Settings.save_provider(
               owner,
               %{mode: "live", provider: "zai_coder", model: nil, key_configured?: true},
               "rollback-test-key"
             )

    assert Settings.provider_key(owner, :zai_coder) == {:error, :not_configured}
  end

  test "existing browser identities receive a persistent signed cookie" do
    owner = Ash.UUIDv7.generate()
    conn = build_conn() |> Plug.Test.init_test_session(%{browser_id: owner}) |> get("/")
    assert Plug.Conn.get_session(conn, :browser_id) == owner
    assert conn.resp_cookies["_agent_examples"].max_age == 31_536_000

    assert Enum.any?(
             Plug.Conn.get_resp_header(conn, "set-cookie"),
             &String.contains?(&1, "HttpOnly")
           )
  end
end
