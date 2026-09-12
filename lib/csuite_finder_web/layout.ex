defmodule CsuiteFinderWeb.Layout do
  @moduledoc """
  The parts every page shares: the document head, the stylesheet, the footer.

  These pages are plain EEx templates rendered straight to a string — there is
  no Phoenix layout between them. Without this module the same 150 lines of
  `<head>`, colour tokens and base CSS lived in five files, and every one of
  them was a place for the site to drift: a colour changed on three pages, a
  page quietly missing the analytics tag, a nav link updated everywhere but one.

  A page now supplies only what is genuinely its own:

      <%= Layout.head(title: "Get started — CSuiteFinder",
                      description: "...",
                      nav: :start,
                      css: page_css()) %>
      ...the page...
      <%= Layout.footer(:default) %>
      </div>
      </body>
      </html>

  `head/1` opens the document and the `.wrap` div and renders the nav; the page
  closes them. The closing tags stay in the page because several pages put a
  `<script>` between the wrapper and `</body>`, and a partial that swallowed
  them would have to take the scripts as a string argument — which is worse than
  four lines of boilerplate.
  """

  require EEx

  @partials Path.join(:code.priv_dir(:csuite_finder), "templates/partials")

  @head Path.join(@partials, "head.html.eex")
  @external_resource @head
  EEx.function_from_file(:defp, :render_head, @head, [:assigns])

  # Static, so it is read once at compile time rather than rendered per request.
  @base_css_path Path.join(@partials, "base.css")
  @external_resource @base_css_path
  @base_css File.read!(@base_css_path)

  @sheet Path.join(@partials, "sheet.html.eex")
  @external_resource @sheet
  EEx.function_from_file(:defp, :render_sheet, @sheet, [:assigns])

  @chat Path.join(@partials, "chat.html.eex")
  @external_resource @chat
  EEx.function_from_file(:defp, :render_chat, @chat, [:assigns])

  @ai Path.join(@partials, "ai.html.eex")
  @external_resource @ai
  EEx.function_from_file(:defp, :render_ai, @ai, [:assigns])

  @footer Path.join(@partials, "footer.html.eex")
  @external_resource @footer
  EEx.function_from_file(:defp, :render_footer, @footer, [:assigns])

  @doc """
  Everything from `<!DOCTYPE html>` to the open `.wrap` div, nav included.

  Options:

    * `:title` — the `<title>`. Required; a page with no title is a bug.
    * `:description` — the meta description, or `nil` for pages search engines
      should not be reading anyway.
    * `:robots` — a robots directive, e.g. `"noindex"`. Omitted when `nil`.
    * `:refresh` — seconds for a meta refresh (the admin dashboard uses it).
    * `:nav` — which nav item to mark current, or `false` for no nav at all.
    * `:audience` — `:sales` or `:developer` when the page settles which half of
      the business the visitor is in, omitted when it does not. See
      `CsuiteFinderWeb.Nav`.
    * `:css` — this page's own CSS, appended after the shared sheet.
    * `:wrap_class` — `"wrap"` (default), `"wrap-narrow"` or `"wrap-wide"`.
  """
  @spec head(keyword()) :: String.t()
  def head(opts) do
    render_head(%{
      title: Keyword.fetch!(opts, :title),
      description: Keyword.get(opts, :description),
      robots: Keyword.get(opts, :robots),
      refresh: Keyword.get(opts, :refresh),
      nav: Keyword.get(opts, :nav, nil) |> nav_key(),
      audience: Keyword.get(opts, :audience),
      css: Keyword.get(opts, :css, ""),
      wrap_class: Keyword.get(opts, :wrap_class, "wrap")
    })
  end

  # `nav: false` means no nav; `nav: nil` means a nav with nothing marked
  # current. Both are useful, so they cannot collapse into one value.
  defp nav_key(false), do: nil
  defp nav_key(nil), do: :none
  defp nav_key(key) when is_atom(key), do: key

  @doc "The shared stylesheet, without the surrounding `<style>` tags."
  @spec base_css() :: String.t()
  def base_css, do: @base_css

  # Third in the sheet, which is the cell the cursor sits on — someone arriving
  # from an emailed link finds their own address already selected.
  defp with_visitor(rows, nil), do: rows

  defp with_visitor([first | rest], visitor), do: [first, visitor | rest]

  defp with_visitor([], visitor), do: [visitor]

  # One .css file per page, read at compile time. Keeping them beside the
  # templates rather than inside the controllers means a design change is a CSS
  # edit, and `@external_resource` makes the module recompile when one changes.
  @page_css_dir Path.join(:code.priv_dir(:csuite_finder), "templates/pages")

  for path <- Path.wildcard(Path.join(@page_css_dir, "*.css")) do
    @external_resource path
    @doc false
    def page_css(unquote(String.to_atom(Path.basename(path, ".css")))),
      do: unquote(File.read!(path))
  end

  @doc """
  This page's own CSS, from `priv/templates/pages/<name>.css`.

  An unknown name is an empty sheet rather than a crash: a page that renders
  unstyled is a visible, fixable problem; a 500 in production is not.
  """
  @spec page_css(atom()) :: String.t()
  def page_css(_other), do: ""

  @doc """
  The sample spreadsheet, as shown on the home, sales and developer pages.

  Options: `:rows` (from `CsuiteFinderWeb.SampleSheet`), `:rows_label` for the
  figure in the status bar, `:date` for the caption, `:visitor` — a row built
  from the details an emailed link carried, slotted in third so it lands under
  the cell cursor — and `:count`, which replaces the status bar's text outright
  for a page selling something other than a monthly allowance.
  """
  @spec sheet(keyword()) :: String.t()
  def sheet(opts) do
    rows_label = Keyword.fetch!(opts, :rows_label)

    render_sheet(%{
      rows: with_visitor(Keyword.fetch!(opts, :rows), Keyword.get(opts, :visitor)),
      rows_label: rows_label,
      date: Keyword.fetch!(opts, :date),
      # What the status bar says. A seat is sold by the month, so a monthly row
      # count is the figure that means something there; the API is sold per
      # answer, and a page quoting a monthly allowance to someone buying credit
      # is quoting them the wrong product's number.
      count: Keyword.get(opts, :count) || ~s(Rows <strong>#{rows_label}</strong> / month)
    })
  end

  @doc """
  The sample conversation, shown above the sheet.

  One partial because it sits on every page that shows the sheet, and the two
  are a pair: the file the assistant hands back in the chat is the sheet
  underneath it. Five copies would be five places to forget.

  It carries `data-aud` blocks for the per-call prices, so a seat holder is not
  quoted a per-answer figure, and `data-signed` blocks so a visitor who already
  has a key sees their own. Both default to the safe half with no script at all.

  Takes `:base_url` — the canonical public URL, because the line in the first
  bubble is meant to be pasted and must name this service rather than whatever
  host a request arrived with.
  """
  @spec chat(keyword()) :: String.t()
  def chat(opts) do
    render_chat(%{base_url: Keyword.fetch!(opts, :base_url)})
  end

  @doc """
  The AI integration pitch — the second thing every page says.

  Site-wide and shared, because it is a claim rather than a feature list: if the
  home page and the sales page describe the integration differently, one of them
  is wrong. Only the three supporting points change with the audience, since a
  salesperson wants to hear there is no terminal and an engineer wants to hear
  there is no SDK.

  Options: `:audience` (`:sales` or `:developer`) and `:base_url`, which is the
  canonical public URL rather than the request's Host header — the snippet is
  meant to be pasted, so it has to name this service and not whatever host a
  forged request arrived with.
  """
  @spec ai(keyword()) :: String.t()
  def ai(opts) do
    render_ai(%{
      audience: Keyword.get(opts, :audience, :developer),
      base_url: Keyword.fetch!(opts, :base_url)
    })
  end

  @doc """
  The site footer.

  Takes an audience, because the footer is a second place a salesperson can trip
  over the developer offer: `llms.txt` and a JSON price list are not links that
  belong under a seat plan. `:default` is the fork page, which shows both. A list
  of `{href, label}` pairs gives a page its own set — the admin dashboard's
  footer is operator links, not customer ones.
  """
  @spec footer(:default | :sales | :developer | [{String.t(), String.t()}]) :: String.t()
  def footer(links \\ :default)

  def footer(:default) do
    footer([
      {"/", "Home"},
      {"/teams", "For sales teams"},
      {"/developers", "For developers"},
      {"/start", "Get started"},
      {"/account", "Your account"},
      {"/privacy", "Privacy"}
    ])
  end

  def footer(:sales) do
    footer([
      {"/teams", "Home"},
      {"/teams#pricing", "Pricing"},
      # The seat's answer to "how do I actually use this" is an assistant
      # pointed at llms.txt, and that walkthrough is /start. It belongs in
      # front of a seat holder, not only a developer.
      {"/start", "Get started"},
      {"/account", "Your account"},
      {"/privacy", "Privacy"}
    ])
  end

  def footer(:developer) do
    footer([
      {"/developers", "Home"},
      {"/start", "Get started"},
      {"/developers#pricing", "Pricing"},
      {"/llms.txt", "llms.txt"},
      {"/csuitefinder/pricing", "pricing as JSON"},
      {"/account", "Your account"},
      {"/privacy", "Privacy"}
    ])
  end

  def footer(links) when is_list(links) do
    render_footer(%{
      # Taken from the clock rather than written down, so it is not a thing
      # somebody has to remember to change every January.
      year: Date.utc_today().year,
      links:
        Enum.map_join(links, " ·\n  ", fn {href, label} -> ~s(<a href="#{href}">#{label}</a>) end)
    })
  end

  @doc """
  Where a privacy request goes.

  The operator's own address, because it is the one that exists. A `privacy@`
  alias would read better and would be a mailbox nobody had created — a notice
  that names an address which bounces is worse than one that names none, since
  the person has then been told their request was sent when it was not.

  Configurable, so it can move to a real alias the day one exists.
  """
  @spec privacy_contact() :: String.t()
  def privacy_contact do
    Application.get_env(:csuite_finder, :privacy_contact, "lbesecker195@gmail.com")
  end

  @doc """
  The date the privacy policy last changed, in words.

  Written down rather than taken from the clock: "last updated" has to mean the
  last time the text changed, and a date from `Date.utc_today/0` would claim a
  revision every morning.
  """
  @spec privacy_updated_on() :: String.t()
  def privacy_updated_on, do: "11 September 2026"
end
