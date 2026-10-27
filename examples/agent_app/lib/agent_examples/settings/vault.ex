defmodule AgentExamples.Settings.Vault do
  @moduledoc "Encrypts example credentials using a persistent, locally generated AES-GCM key."
  use Cloak.Vault, otp_app: :agent_examples

  @impl true
  def init(config) do
    directory = Application.fetch_env!(:agent_examples, :settings_directory)
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    key = load_or_create_key(Path.join(directory, "credential.key"))

    {:ok,
     Keyword.put(config, :ciphers, default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key})}
  end

  defp load_or_create_key(path) do
    unless File.exists?(path), do: create_key_file(path)
    File.chmod!(path, 0o600)
    key = File.read!(path)

    if byte_size(key) != 32,
      do:
        raise(
          "The example credential.key must contain 32 bytes; restore the original key to decrypt existing credentials."
        )

    key
  end

  defp create_key_file(path) do
    temporary = path <> ".#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.open!(temporary, [:write, :binary, :exclusive], fn file ->
        File.chmod!(temporary, 0o600)
        IO.binwrite(file, :crypto.strong_rand_bytes(32))
      end)

      case File.ln(temporary, path) do
        :ok ->
          :ok

        {:error, :eexist} ->
          :ok

        {:error, reason} ->
          raise File.Error, reason: reason, action: "create encryption key", path: path
      end
    after
      File.rm(temporary)
    end
  end
end
