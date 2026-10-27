defmodule AgentExamplesWeb.Layouts do
  use Phoenix.Component
  @stylesheet Path.expand("../../priv/static/assets/app.css", __DIR__)
  @external_resource @stylesheet
  @stylesheet_url "/assets/app.css?v=" <>
                    Base.encode16(:crypto.hash(:sha256, File.read!(@stylesheet)), case: :lower)

  defp stylesheet_url, do: @stylesheet_url

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="color-scheme" content="dark" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Aikido · Agent playground</title>
        <link rel="stylesheet" href={stylesheet_url()} />
        <link rel="stylesheet" href="/aikido/inspector/inspector.css" />
        <script type="module" src="/assets/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
