defmodule Aikido.AiReact.ModelRequestTracing do
  @moduledoc "Preserves native Ash trace context at the HTTP request execution boundary."

  @doc "Adds a transient Req plugin without replacing application-owned plugins or adapters."
  def options(options, tracers) do
    transfer = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers)

    plugin = fn request ->
      Req.Request.prepend_request_steps(request,
        aikido_trace_context: fn request ->
          Ash.ProcessHelpers.transfer_context(transfer)
          request
        end
      )
    end

    Keyword.update(options, :req_http_options, [plugins: [plugin]], fn http_options ->
      Keyword.update(http_options, :plugins, [plugin], &(&1 ++ [plugin]))
    end)
  end
end
