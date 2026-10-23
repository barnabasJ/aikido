defimpl AshLua.Error, for: Ash.Error.Invalid.NoSuchInput do
  def to_error(error) do
    inputs = error.inputs |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()

    %{
      message:
        "Unknown input `#{error.input}` for #{error.action}. " <>
          "Use the accepted input keys: #{Enum.join(inputs, ", ")}. " <>
          "Pass action arguments under `input`; check lua_docs for the exact call signature.",
      short_message: "Unknown action input",
      code: "no_such_input",
      fields: [error.input],
      vars: %{inputs: inputs}
    }
  end
end
