defmodule CsuiteFinder.Inference do
  @moduledoc """
  The last resort: ask a language model when no provider could answer.

  Two questions only, both asked with a hard output ceiling because both have
  one-line answers and an unbounded reply is an unbounded bill:

    * **A job title** (`title/2`, 8 output tokens). Enrichment often returns a
      person with no position, and a title is the field a salesperson actually
      reads.
    * **A company's email format** (`email_pattern/2`, 10 output tokens), when
      the pattern provider has never heard of the domain. One pattern resolves
      every employee at that company for free afterwards, so a good guess here
      is worth far more than it costs.

  ## This is inference, and it is labelled as such

  A model's answer is a plausible answer, not a checked one. Everything it
  produces is stored with `source: "inferred"` and a confidence that says so,
  exactly like the local name-splitting fallback next door in
  `CsuiteFinder.People`. A guess dressed as a verified record poisons the cache
  for every later caller.

  Both answers are **validated before they are believed**. A pattern has to
  parse in our own token language and survive being applied to a real name; a
  title has to be short, single-line and not the model saying it does not know.
  Anything else is treated as a miss. The model is a witness, not an authority.

  ## Switched off unless configured

  With no `ANTHROPIC_API_KEY` the functions return `:unknown` without making a
  request, and every caller already has a path for that — this is a fallback
  behind a fallback, and nothing depends on it being available.
  """

  require Logger

  alias CsuiteFinder.Patterns

  @endpoint "/v1/messages"
  @api_version "2023-06-01"
  @default_model "claude-haiku-4-5-20251001"

  # Small on purpose. "Chief Financial Officer" is four tokens and "{first}.{last}"
  # is under ten; anything longer than this is the model ignoring the brief, and
  # truncation is the cheapest way to find out.
  @title_max_tokens 8
  @pattern_max_tokens 10

  # Haiku list prices, in micro-USD per token, so the admin dashboard's margin
  # stays honest about what a fallback costs us.
  @input_micro_per_token 1
  @output_micro_per_token 5

  @title_system """
  You state people's job titles. Reply with the person's current job title at \
  the company given and nothing else — no punctuation, no sentence, no name. \
  Use the standard abbreviation where one exists: CEO, CFO, CTO, COO, CMO, CIO, \
  CSO, CRO, EVP, SVP, VP. If you are not confident, reply UNKNOWN.\
  """

  @pattern_system """
  You state how a company formats employee email addresses. Reply with one \
  pattern and nothing else, built only from these tokens: {first} {last} \
  {middle} {f} {l} {m}, joined by . _ - or nothing. Examples: {first}.{last} \
  {f}{last} {first}_{last}. If you are not confident, reply UNKNOWN.\
  """

  @type answer :: {:ok, String.t(), non_neg_integer()} | :unknown

  @doc "Is the model fallback available in this environment?"
  @spec configured?() :: boolean()
  def configured?, do: is_binary(api_key()) and api_key() != ""

  @doc """
  The person's job title, abbreviated.

  Returns `{:ok, title, cost_micro}` or `:unknown`.
  """
  @spec title(String.t(), String.t()) :: answer()
  def title(full_name, company) when is_binary(full_name) and is_binary(company) do
    ask(@title_system, "#{full_name} — #{company}", @title_max_tokens, &validate_title/1)
  end

  def title(_, _), do: :unknown

  @doc """
  The company's email pattern, in our canonical token form.

  Returns `{:ok, pattern, cost_micro}` or `:unknown`.
  """
  @spec email_pattern(String.t(), String.t() | nil) :: answer()
  def email_pattern(domain, company \\ nil) when is_binary(domain) do
    prompt = if company, do: "#{domain} (#{company})", else: domain
    ask(@pattern_system, prompt, @pattern_max_tokens, &validate_pattern/1)
  end

  # ------------------------------------------------------------- validation

  # A model that does not know tends to start explaining rather than stop, and
  # an eight-token ceiling turns the explanation into a fragment. A fragment is
  # still not a job title, so hedging language and anything longer than a title
  # gets thrown away. These two rules are cheaper and more reliable than trying
  # to parse a title out of a sentence.
  @hedges ~w(not unknown cannot unable sorry information sure know find found
             believe appears likely probably possibly assume based available
             public data unfortunately there here would could)

  defp validate_title(text) do
    trimmed = text |> String.trim() |> String.trim(".")
    words = String.split(trimmed, ~r/\s+/, trim: true)

    cond do
      trimmed == "" -> :unknown
      String.contains?(trimmed, "\n") -> :unknown
      String.length(trimmed) > 48 -> :unknown
      # "EVP & Chief Financial Officer" is five. Nothing real is longer.
      length(words) > 6 -> :unknown
      Enum.any?(words, &(String.downcase(String.trim(&1, ",")) in @hedges)) -> :unknown
      true -> {:ok, trimmed}
    end
  end

  # A pattern has to be one we can actually apply. Parsing it is not enough:
  # `{first}{first}` parses and is nonsense, so it is applied to a real name and
  # rejected unless it produces a plausible local-part.
  defp validate_pattern(text) do
    candidate = text |> String.trim() |> String.trim(".") |> String.downcase()

    with true <- Regex.match?(~r/^(?:\{(?:first|last|middle|f|l|m)\}|[._-])+$/, candidate),
         true <- String.contains?(candidate, ["{first}", "{last}", "{f}", "{l}"]),
         {:ok, local} <-
           Patterns.apply_pattern(canonical(candidate), %{
             first: "jane",
             last: "doe",
             middle: "q"
           }),
         true <- local != "" and String.length(local) <= 64 do
      {:ok, canonical(candidate)}
    else
      _ -> :unknown
    end
  end

  # `{m}` is our own short form for a middle initial; the pattern language
  # spells single initials as `{f}` / `{l}` / `{m}` already, so this is a no-op
  # for well-formed answers and a normaliser for sloppy ones.
  defp canonical(pattern), do: String.replace(pattern, "{middle}", "{m}")

  # ----------------------------------------------------------------- client

  defp ask(system, prompt, max_tokens, validate) do
    if configured?() do
      case request(system, prompt, max_tokens) do
        {:ok, text, cost} ->
          case validate.(text) do
            {:ok, value} -> {:ok, value, cost}
            :unknown -> :unknown
          end

        :error ->
          :unknown
      end
    else
      :unknown
    end
  end

  defp request(system, prompt, max_tokens) do
    body = %{
      model: model(),
      max_tokens: max_tokens,
      system: system,
      messages: [%{role: "user", content: prompt}]
    }

    options =
      [
        url: base_url() <> @endpoint,
        json: body,
        headers: [
          {"x-api-key", api_key()},
          {"anthropic-version", @api_version}
        ],
        receive_timeout: 10_000
      ] ++ plug_option()

    case Req.post(options) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, text_of(response), cost_of(response)}

      {:ok, %{status: status, body: response}} ->
        Logger.warning("inference #{status}: #{inspect(response)}")
        :error

      {:error, reason} ->
        Logger.warning("inference transport: #{inspect(reason)}")
        :error
    end
  end

  defp text_of(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join(" ", & &1["text"])
  end

  defp text_of(_), do: ""

  defp cost_of(%{"usage" => %{"input_tokens" => input, "output_tokens" => output}}) do
    input * @input_micro_per_token + output * @output_micro_per_token
  end

  defp cost_of(_), do: 0

  defp plug_option do
    case config()[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end

  defp config, do: Application.get_env(:csuite_finder, __MODULE__, [])
  defp api_key, do: config()[:api_key]
  defp model, do: config()[:model] || @default_model
  defp base_url, do: config()[:base_url] || "https://api.anthropic.com"
end
