defmodule Aikido.Actions.Scheduling.ScheduleCron do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    cron_expr = input.arguments[:cron]
    job_id = input.arguments[:job_id]
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    tz = input.arguments[:timezone]
    signal = struct!(Jido.Signal, id: nil, type: type, data: payload, source: "/cron")

    opts =
      if job_id do
        [job_id: job_id]
      else
        []
      end

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
