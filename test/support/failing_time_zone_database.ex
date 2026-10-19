defmodule AikidoTest.Support.FailingTimeZoneDatabase do
  @moduledoc false
  @behaviour Calendar.TimeZoneDatabase

  @impl true
  def time_zone_period_from_utc_iso_days(_iso_days, _time_zone) do
    if observer = :persistent_term.get({__MODULE__, :observer}, nil) do
      send(observer, {:time_zone_resolution_failed, self()})
    end

    {:error, :time_zone_not_found}
  end

  @impl true
  def time_zone_periods_from_wall_datetime(_datetime, _time_zone) do
    if observer = :persistent_term.get({__MODULE__, :observer}, nil) do
      send(observer, {:time_zone_resolution_failed, self()})
    end

    {:error, :time_zone_not_found}
  end
end
