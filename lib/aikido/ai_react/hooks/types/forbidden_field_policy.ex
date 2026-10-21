defmodule Aikido.AiReact.Hooks.Types.ForbiddenFieldPolicy do
  @moduledoc "How AshLua represents fields hidden by authorization."
  use Ash.Type.Enum,
    values: [
      hide: "Omit fields hidden by authorization.",
      display: "Represent hidden fields with an opaque marker."
    ]
end
