defmodule Aikido.AiReact.Types.RequestMode do
  @moduledoc "Kinds of model requests issued by the ReAct slice."
  use Ash.Type.Enum,
    values: [
      normal: "Generate the next conversation turn.",
      handoff: "Generate a context handoff summary.",
      resume: "Resume model work after a handoff."
    ]
end
