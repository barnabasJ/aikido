defmodule AgentExamplesWeb.Components.TelemetryChart do
  @moduledoc "Small SVG time-series charts shared by the telemetry overview."
  use Phoenix.Component
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:unit, :string, required: true)
  attr(:note, :string, required: true)
  attr(:points, :list, required: true)
  attr(:series, :list, required: true)

  def chart(assigns) do
    values =
      for point <- assigns.points,
          {key, _, _} <- assigns.series,
          value = point[key],
          is_number(value),
          do: value

    maximum = Enum.max(values, fn -> 0 end) |> max(1)
    first = List.first(assigns.points)
    last = List.last(assigns.points)
    start = if first, do: first.at, else: 0
    span = if last, do: max(last.at - start, 1000), else: 1000

    lines =
      for {key, label, color} <- assigns.series do
        %{label: label, color: color, path: path(assigns.points, key, start, span, maximum)}
      end

    assigns =
      assign(assigns,
        maximum: maximum,
        lines: lines,
        available: values != [],
        first: time(first),
        last: time(last)
      )

    ~H"""
    <section class="col-lg-6 mb-3" id={@id}>
      <div class="card h-100">
        <div class="card-body">
          <h3 class="h6">{@title}</h3>
          <p class="small text-muted">{@note}</p>
          <svg viewBox="0 0 600 190" role="img" aria-label={@title} style="width:100%;height:auto">
            <g :for={fraction <- [0, 0.5, 1]}>
              <line
                x1="55"
                x2="585"
                y1={150 - fraction * 130}
                y2={150 - fraction * 130}
                stroke="#cbd5e1"
                stroke-width="1"
              />
              <text x="49" y={154 - fraction * 130} text-anchor="end" fill="#64748b" font-size="11">
                {Float.round(@maximum * fraction / 1, 2)}
              </text>
            </g>
            <path
              :for={line <- @lines}
              d={line.path}
              fill="none"
              stroke={line.color}
              stroke-width="2"
            />
            <text x="55" y="175" fill="#64748b" font-size="11">{@first}</text>
            <text x="585" y="175" text-anchor="end" fill="#64748b" font-size="11">{@last}</text>
            <text :if={!@available} x="320" y="85" text-anchor="middle" fill="#64748b" font-size="12">
              No signal durations observed yet
            </text>
          </svg>
          <div class="small">
            <span :for={line <- @lines} style={"color:#{line.color};margin-right:16px"}>● {line.label}</span><span class="text-muted">{@unit} · UTC</span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp path(points, key, start, span, maximum) do
    {segments, _} =
      Enum.map_reduce(points, false, fn point, drawing ->
        case point[key] do
          value when is_number(value) ->
            x = Float.round(55 + (point.at - start) / span * 530, 2)
            y = Float.round(150 - value / maximum * 130, 2)
            {"#{if drawing, do: "L", else: "M"}#{x},#{y}", true}

          _ ->
            {"", false}
        end
      end)

    Enum.join(segments, " ")
  end

  defp time(nil), do: ""

  defp time(point),
    do: point.at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
end
