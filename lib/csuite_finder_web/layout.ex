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
  The site footer.

  `:default` gives the links every marketing page carries. A list of
  `{href, label}` pairs gives a page its own set — the admin dashboard's footer
  is operator links, not customer ones.
  """
  @spec footer(:default | [{String.t(), String.t()}]) :: String.t()
  def footer(links \\ :default)

  def footer(:default) do
    footer([
      {"/", "Home"},
      {"/teams", "For sales teams"},
      {"/developers", "For developers"},
      {"/start", "Get started"},
      {"/account", "Your account"},
      {"/llms.txt", "llms.txt"},
      {"/csuitefinder/health", "status"}
    ])
  end

  def footer(links) when is_list(links) do
    render_footer(%{
      links:
        Enum.map_join(links, " ·\n  ", fn {href, label} -> ~s(<a href="#{href}">#{label}</a>) end)
    })
  end
end
