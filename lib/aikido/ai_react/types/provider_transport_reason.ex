defmodule Aikido.AiReact.Types.ProviderTransportReason do
  @moduledoc "Public transport failure reasons without response or exception text."
  use Ash.Type.Enum,
    values: [
      :timeout,
      :closed,
      :econnrefused,
      :econnreset,
      :pool_not_available,
      :nxdomain,
      :enetunreach
    ]
end
