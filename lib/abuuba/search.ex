defmodule Abuuba.Search do
  @moduledoc """
  What somebody typed into the search box, and what it finds.

  ## Operators are parsed here, not in the page

  `from:bob has:media before:2026-08-01 gardening` is one string a person
  typed, and turning it into a query is a job with edges: an operator nobody
  defined, a date nobody could mean, a handle that resolves to nobody. Doing it
  in a LiveView would mean doing it again in the API, and the two would
  disagree about `before:soon`.

  ## Anything unrecognised stays in the words

  `colour:blue` is not an operator, so it is text, and somebody searching for
  that string finds it. Silently dropping a token because it has a colon in it
  would make the box quietly ignore part of the question.

  ## An operator that resolves to nobody finds nothing

  `from:nobody` narrows to an author who does not exist, so the answer is
  empty. Ignoring the operator instead would answer a narrower question with a
  wider answer, which is the failure mode people notice last.

  The matching itself is still a containment scan; the real index arrives with
  its own issue. This is the shape the query takes, so swapping the engine
  underneath changes one function rather than every caller.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Search.Postgres
  alias Abuuba.Search.Query
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag

  @typedoc "A parsed query: the words, and whatever narrowed them."
  @type t :: Query.t()

  @doc "Posts matching a parsed query, as far as this reader may see them."
  @callback statuses(Query.t(), Account.t() | integer() | nil, keyword()) :: [Status.t()]

  @doc "Accounts matching a parsed query."
  @callback accounts(Query.t(), Account.t() | integer() | nil, keyword()) :: [Account.t()]

  @doc "Hashtags matching a parsed query."
  @callback tags(Query.t(), Account.t() | integer() | nil, keyword()) :: [Tag.t()]

  @doc """
  Which engine answers.

  Postgres unless a server says otherwise. The behaviour is what lets somebody
  who has outgrown it slot in something else without touching a call site.
  """
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:abuuba, :search_adapter, Postgres)

  @doc """
  Splits what somebody typed into words and operators.
  """
  @spec parse(String.t() | nil) :: Query.t()
  def parse(nil), do: %Query{}

  def parse(query) when is_binary(query) do
    {operators, words} =
      query
      |> tokens()
      |> Enum.reduce({%{}, []}, &take_token/2)

    %Query{text: words |> Enum.reverse() |> Enum.join(" "), operators: operators}
  end

  def parse(_query), do: %Query{}

  @doc """
  Posts matching what somebody typed, as far as they may see them.
  """
  @spec statuses(String.t() | nil, Account.t() | integer() | nil, keyword()) :: [Status.t()]
  def statuses(query, viewer, opts \\ []) do
    parsed = parse(query)

    if empty?(parsed), do: [], else: adapter().statuses(parsed, viewer, opts)
  end

  @doc """
  Accounts matching what somebody typed.

  A handle carrying a domain narrows to that server, because `bob@other.example`
  names one person and not everybody called bob.
  """
  @spec accounts(String.t() | nil, Account.t() | integer() | nil, keyword()) :: [Account.t()]
  def accounts(query, viewer, opts \\ []) do
    parsed = query |> parse() |> split_handle()

    if parsed.text == "", do: [], else: adapter().accounts(parsed, viewer, opts)
  end

  @doc """
  Hashtags matching what somebody typed.
  """
  @spec tags(String.t() | nil, Account.t() | integer() | nil, keyword()) :: [Tag.t()]
  def tags(query, viewer, opts \\ []) do
    parsed = parse(query)

    if parsed.text == "", do: [], else: adapter().tags(parsed, viewer, opts)
  end

  @doc """
  The operators the box understands, for an interface that wants to say so.

  Read from here rather than written out in a template, because a UI offering
  an operator the parser does not know is a UI that lies.
  """
  @spec operators() :: [%{name: String.t(), example: String.t(), description: String.t()}]
  def operators do
    [
      %{name: "from:", example: "from:alice", description: "posts by one person"},
      %{name: "has:", example: "has:media", description: "posts carrying a picture or a poll"},
      %{name: "is:", example: "is:reply", description: "replies, boosts or sensitive posts"},
      %{name: "language:", example: "language:de", description: "posts written in one language"},
      %{name: "in:", example: "in:library", description: "only what you wrote or kept"},
      %{name: "before:", example: "before:2026-01-01", description: "posts older than a date"},
      %{name: "after:", example: "after:2026-01-01", description: "posts newer than a date"},
      %{name: "during:", example: "during:2026-01-01", description: "posts from one day"}
    ]
  end

  ## Parsing

  # Quoted phrases survive tokenising, because `websearch_to_tsquery` reads
  # them and splitting on every space would take the quotes apart first.
  defp tokens(query) do
    ~r/"[^"]*"|\S+/
    |> Regex.scan(query)
    |> Enum.map(&hd/1)
  end

  # `is:` and `has:` accumulate; everything else keeps the last one written.
  #
  # Two of those are a refinement -- `is:reply is:sensitive` is a sensible
  # thing to ask for, and the guide says the operators combine with each other
  # -- and collapsing them returned a *wider* set than was asked for, which is
  # the direction nobody notices. Two `from:` or two `language:` terms are a
  # contradiction rather than a refinement, so those still take the last.
  @accumulating [:is, :has]

  defp take_token(token, {operators, words}) do
    case String.split(token, ":", parts: 2) do
      [name, value] when value != "" ->
        case operator(name, value) do
          {key, parsed} -> {collect(operators, key, parsed), words}
          nil -> {operators, [token | words]}
        end

      _ ->
        {operators, [token | words]}
    end
  end

  defp collect(operators, key, parsed) when key in @accumulating do
    Map.update(operators, key, [parsed], &Enum.uniq(&1 ++ [parsed]))
  end

  defp collect(operators, key, parsed), do: Map.put(operators, key, parsed)

  # The leading @ is optional because people type both, and neither is wrong.
  defp operator("from", value), do: {:from, String.trim_leading(value, "@")}
  defp operator("has", value) when value in ~w(media poll), do: {:has, value}
  defp operator("is", value) when value in ~w(reply sensitive boost), do: {:is, value}
  defp operator("in", value) when value in ~w(library public), do: {:in, value}
  defp operator("language", value), do: {:language, String.downcase(value)}
  defp operator("before", value), do: date(:before, value)
  defp operator("after", value), do: date(:after, value)
  defp operator("during", value), do: date(:during, value)
  defp operator(_name, _value), do: nil

  # A date nobody could mean is not an operator. `before:soon` is somebody
  # searching for that text, and the words are where it belongs.
  defp date(key, value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {key, date}
      _ -> nil
    end
  end

  # A query with neither words nor operators is somebody who has typed nothing,
  # and the answer to that is nothing rather than everything.
  defp empty?(%Query{text: "", operators: operators}), do: operators == %{}
  defp empty?(_parsed), do: false

  # `bob@other.example` names one person on one server. The domain is lifted
  # out so the adapter can narrow to it rather than matching the whole handle
  # as text nobody's display name contains.
  defp split_handle(%Query{text: text} = parsed) do
    case String.split(String.trim_leading(text, "@"), "@", parts: 2) do
      [name, domain] when domain != "" ->
        %{parsed | text: name, operators: Map.put(parsed.operators, :domain, domain)}

      _ ->
        %{parsed | text: String.trim_leading(text, "@")}
    end
  end
end
