defmodule AgentExamples.AI.Providers do
  @moduledoc "Provider choices and native ReqLLM model validation for the browser's shared AI settings."

  def defaults, do: %{mode: "offline", provider: "zai", model: "glm-5.3", key_configured?: false}

  def choices do
    ReqLLM.Providers.list()
    |> Enum.sort_by(&{if(&1 in [:zai, :zai_coder], do: 0, else: 1), to_string(&1)})
    |> Enum.map(&{label(&1), to_string(&1)})
  end

  defp label(:zai), do: "z.ai · standard API"
  defp label(:zai_coder), do: "z.ai · coding plan"
  defp label(provider), do: to_string(provider)

  def validate(%{"mode" => "offline"}), do: {:ok, defaults()}

  def validate(params) do
    provider = Enum.find(ReqLLM.Providers.list(), &(to_string(&1) == params["provider"]))
    id = String.trim(params["model"] || "")
    id = if provider, do: String.replace_prefix(id, "#{provider}:", ""), else: id

    with true <- params["mode"] == "live" && not is_nil(provider) && id != "",
         {:ok, _model} <- ReqLLM.model(%{provider: provider, id: id}) do
      {:ok, %{mode: "live", provider: to_string(provider), model: id, key_configured?: true}}
    else
      _ -> {:error, "Select a registered provider and enter a model ID for live mode."}
    end
  end
end
