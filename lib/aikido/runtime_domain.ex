defmodule Aikido.RuntimeDomain do
  @moduledoc "Native Ash domain for reusable runtime operations."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Aikido.AgentServer.RuntimeActions
  end
end
