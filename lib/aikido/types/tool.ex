defmodule Aikido.Types.Tool do
  @moduledoc "A runtime tool object, Aikido action, or Ash resource/action pair."
  use Ash.Type

  def storage_type(_), do: :term
  def cast_input(nil, _), do: :error

  def cast_input(value, _) do
    case Aikido.Slices.AiReact.ToolAdapter.validate_actions([value]) do
      :ok ->
        {:ok, value}

      {:error, _} ->
        {:error,
         message: "must be a runtime ReqLLM.Tool, Aikido action, or Ash resource/action pair"}
    end
  end

  def cast_stored(value, constraints), do: cast_input(value, constraints)
  def dump_to_native(value, _), do: {:ok, value}
end
