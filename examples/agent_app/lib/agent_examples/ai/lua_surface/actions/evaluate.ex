defmodule AgentExamples.AI.LuaSurface.Actions.Evaluate do
  @moduledoc "Evaluates the native AshLua surface and makes returned error tables JSON encodable."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, opts, context) do
    with {:ok, result} <- AshLua.EvalActions.Run.Eval.run(input, opts, context) do
      {:ok, Map.update!(result, :error, &normalize_error/1)}
    end
  end

  defp normalize_error(error) do
    error
    |> AshLua.Encoder.encode_result()
    |> add_unknown_error_guidance()
  end

  defp add_unknown_error_guidance(%{"errors" => errors} = envelope) do
    Map.put(
      envelope,
      "errors",
      Enum.map(errors, fn
        %{"code" => "unknown_error"} = error ->
          Map.update!(
            error,
            "message",
            &(&1 <>
                " The action did not expose a recoverable error. Do not repeat it unchanged; inspect the roster or target state, use another supported action, or report this reference to the operator.")
          )

        error ->
          error
      end)
    )
  end

  defp add_unknown_error_guidance(error), do: error
end
