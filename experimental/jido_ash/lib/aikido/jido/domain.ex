defmodule Aikido.Jido.Domain do
  @moduledoc "Internal domain used when an application does not supply one."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end
