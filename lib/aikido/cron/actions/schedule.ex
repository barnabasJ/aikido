defmodule Aikido.Cron.Actions.Schedule do
  @moduledoc """
  Pure reducer that prepares a recurring signal from `cron` and `signal_type`.

  Preserves `state` and returns a `Cron` directive with `payload`, optional
  `job_id` and `timezone`. Signal metadata and registration are deferred to execution.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    cron_expr = input.arguments[:cron]
    job_id = input.arguments[:job_id]
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    tz = input.arguments[:timezone]
    signal = %Aikido.Signal{id: nil, type: type, data: payload, source: "/cron"}

    opts =
      if is_nil(job_id), do: [], else: [job_id: job_id]

    opts =
      if tz do
        Keyword.put(opts, :timezone, tz)
      else
        opts
      end

    directive = Aikido.Directives.cron(cron_expr, signal, opts)

    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [directive]
    )
  end
end
