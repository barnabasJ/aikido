defmodule Aikido.ModelRequestTracingTest do
  use ExUnit.Case, async: false
  require Ash.Tracer

  alias Aikido.AiReact.ModelRequestTracing

  test "finite native HTTP requests preserve Ash traces and application-owned Req plugins" do
    observer = self()
    marker = make_ref()
    Process.put(:synthetic_request_context, marker)

    plugin = fn request ->
      context = Process.get(:synthetic_request_context)

      Req.Request.prepend_request_steps(request,
        synthetic_request_context: fn request ->
          Process.put(:synthetic_request_context, context)
          request
        end
      )
    end

    adapter = fn request ->
      send(observer, {
        :request_context,
        self(),
        Ash.Tracer.Simple.get_span_context(),
        Process.get(:synthetic_request_context)
      })

      {request,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body:
           Jason.encode!(%{
             id: "synthetic",
             model: "synthetic",
             choices: [
               %{index: 0, message: %{role: "assistant", content: "done"}, finish_reason: "stop"}
             ]
           })
       )}
    end

    model =
      ReqLLM.model!(%{
        provider: :openai,
        id: "synthetic",
        extra: %{"wire" => %{"protocol" => "openai_chat"}}
      })

    Ash.Tracer.span :custom, "native-request-context", Ash.Tracer.Simple do
      trace = Ash.Tracer.Simple.get_span_context()

      options =
        [
          api_key: "synthetic-test-only",
          total_deadline_at: System.system_time(:millisecond) + 10_000,
          req_http_options: [adapter: adapter, plugins: [plugin]]
        ]
        |> ModelRequestTracing.options(Ash.Tracer.Simple)

      assert {:ok, response} = ReqLLM.Generation.generate_text(model, "hi", options)
      assert ReqLLM.Response.text(response) == "done"
      assert_receive {:request_context, request_pid, ^trace, ^marker}
      refute request_pid == self()
    end
  end
end
