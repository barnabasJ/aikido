defmodule Aikido.Notifications.Subscription do
  @moduledoc "A subscription to a named agent publication with receiver-owned topic bindings."

  defstruct [
    :name,
    :resource,
    :publication,
    bindings: [],
    __identifier__: nil,
    __spark_metadata__: nil
  ]

  @doc false
  def schema do
    [
      name: [
        type: :atom,
        doc: "Optional local name distinguishing subscriptions to the same publication."
      ],
      resource: [
        type: :module,
        required: true,
        doc: "Agent resource that owns the publication."
      ],
      publication: [
        type: :atom,
        required: true,
        doc: "Name of the publisher's notification declaration."
      ],
      bindings: [
        type: :keyword_list,
        keys: [*: [type: :atom]],
        default: [],
        doc: "Publisher topic attribute names mapped to attributes on the receiving agent."
      ]
    ]
  end
end
