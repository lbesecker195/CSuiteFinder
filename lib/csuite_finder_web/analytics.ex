defmodule CsuiteFinderWeb.Analytics do
  @moduledoc """
  The Google Analytics tag, rendered into every HTML page.

  Defined once rather than pasted into each template: these pages share no
  layout, so five copies would drift the first time the property changed, and a
  page silently missing the tag is invisible in the numbers rather than
  obviously broken.

  The measurement id is configurable so a staging deployment does not report
  into production's property. Unset means no tag is emitted at all — which is
  what you want in tests and in dev, where the traffic is yours and would only
  pollute the data.
  """

  @default_id "G-632F1T5SQ2"

  @doc "The `<script>` tags, or an empty string when analytics are switched off."
  @spec tag() :: String.t()
  def tag do
    case measurement_id() do
      nil ->
        ""

      id ->
        """
        <!-- Google tag (gtag.js) -->
        <script async src="https://www.googletagmanager.com/gtag/js?id=#{id}"></script>
        <script>
          window.dataLayer = window.dataLayer || [];
          function gtag(){dataLayer.push(arguments);}
          gtag('js', new Date());

          gtag('config', '#{id}');
        </script>
        """
    end
  end

  @doc "The configured measurement id, or nil when analytics are off."
  @spec measurement_id() :: String.t() | nil
  def measurement_id do
    case Application.get_env(:csuite_finder, :ga_measurement_id, @default_id) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
