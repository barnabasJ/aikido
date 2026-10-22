defmodule AgentExamples.Settings.Repo do
  @moduledoc "Local SQLite database for example provider preferences and encrypted credentials."
  use AshSqlite.Repo, otp_app: :agent_examples

  @impl true
  def write_transactions?, do: true
end
