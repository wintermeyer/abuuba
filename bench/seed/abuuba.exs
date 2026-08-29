# Seeds the abuuba side of a benchmark run.
#
# Run inside the release: `bin/abuuba eval 'Code.eval_file("/app/bench/seed/abuuba.exs")'`
# or, in development, `mix run bench/seed/abuuba.exs small`.
#
# The dataset is described by `Abuuba.Bench.Dataset` and this script only writes
# it. The Rails script next door writes the same thing, in the same order, and
# the two are only comparable because neither invents anything.

require Logger

alias Abuuba.Accounts
alias Abuuba.Bench.Dataset
alias Abuuba.Relationships
alias Abuuba.Repo
alias Abuuba.Statuses

# The environment first, then argv. Inside a release this runs through
# `bin/abuuba rpc`, which executes on the already-started node and therefore has
# the Repo and Oban available — but the node's `System.argv/0` is the release's
# own start arguments, not anything the harness passed. `bin/abuuba eval` would
# forward argv and is useless here for the opposite reason: it starts a fresh
# node with no application, so the first `Repo.insert` fails with "could not
# lookup Ecto repo Abuuba.Repo because it was not started".
profile =
  case {System.get_env("BENCH_PROFILE"), System.argv()} do
    {name, _argv} when is_binary(name) and name != "" -> name
    {_none, [name | _rest]} -> name
    {_none, []} -> "small"
  end

# Left as the string it arrived as: a size is a follower count as often as it
# is a name, and `Abuuba.Bench.Dataset` resolves either. Checked here so a typo
# stops now rather than seeding nothing and measuring an empty instance.
Dataset.profile(profile) ||
  raise(ArgumentError, "unknown benchmark size #{inspect(profile)}")

domain = Abuuba.Federation.URIs.local_domain()

{:ok, subject} =
  Accounts.create_account(%{
    username: Dataset.subject(),
    display_name: "Benchmark subject",
    uri: "https://#{domain}/users/#{Dataset.subject()}"
  })

{:ok, user} =
  Accounts.create_user(%{
    account_id: subject.id,
    email: "bench@bench.invalid",
    approved: true,
    confirmed_at: DateTime.utc_now()
  })

# The measurements read a home timeline and make a post, both of which need a
# token. Printed rather than stored: the harness reads it off stdout and it
# dies with the container.
# `name`, not the API's `client_name`: the controller translates that spelling
# and this goes straight to the context. And three elements, not two — the
# client secret is returned alongside, because it is never recoverable later.
{:ok, application, _client_secret} =
  Abuuba.OAuth.create_application(%{
    "name" => "benchmark",
    "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
    "scopes" => "read write"
  })

{:ok, _token, raw_token} = Abuuba.OAuth.issue_token(application, user, ["read", "write"])

Logger.info("seeding #{Dataset.describe(profile)}")

# One pass in chunks: the accounts, the person behind each of them, and the
# follow, all written before the next chunk is built.
#
# Streamed rather than built as three full lists, and the ids come back from
# the insert rather than from a query afterwards. Reading them back with
# `where username in ^followers` worked at a thousand and could never have
# worked at scale: Postgres takes at most 65535 bind parameters, so the
# hundred-thousand profile that was already in the dataset would have failed on
# that line, and a million is fifteen times past the wall. Nobody had run it.
#
# A signed-in person behind every follower because the two servers disagree
# about who is worth fanning out to, and the disagreement would otherwise
# decide the result. Mastodon delivers only to local followers with a user
# record and a recent sign-in (`followers_for_local_distribution` merges
# `User.signed_in_recently`); abuuba delivers to a follower with no user record
# at all (`Abuuba.Timelines.FanOut.audience/1`). Seeded as bare accounts, the
# same thousand followers meant a thousand deliveries on abuuba and none on
# Mastodon, which reads as Mastodon being unmeasurably fast at the thing it was
# skipping.
chunk_size = 1_000
now = DateTime.utc_now()

seeded =
  profile
  |> Dataset.followers()
  |> Stream.chunk_every(chunk_size)
  |> Enum.reduce(0, fn handles, seen ->
    accounts =
      Enum.map(handles, fn handle ->
        %{
          username: handle,
          display_name: handle,
          uri: "https://#{domain}/users/#{handle}",
          note: "",
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, inserted} =
      Repo.insert_all(Abuuba.Accounts.Account, accounts,
        on_conflict: :nothing,
        returning: [:id, :username]
      )

    Repo.insert_all(
      Abuuba.Accounts.User,
      Enum.map(inserted, fn account ->
        %{
          account_id: account.id,
          email: "#{account.username}@bench.invalid",
          approved: true,
          confirmed_at: now,
          last_signed_in_at: now,
          inserted_at: now,
          updated_at: now
        }
      end),
      on_conflict: :nothing
    )

    Repo.insert_all(
      Abuuba.Relationships.Follow,
      Enum.map(inserted, fn account ->
        %{
          account_id: account.id,
          target_account_id: subject.id,
          show_reblogs: true,
          notify: false,
          inserted_at: now,
          updated_at: now
        }
      end),
      on_conflict: :nothing
    )

    seen = seen + length(inserted)
    if rem(seen, 100_000) == 0, do: Logger.info("seeded #{seen} followers")
    seen
  end)

# The follows above went in as bulk rows, which skips the counter caches a
# real follow maintains. Recounted here from the rows, so the subject's
# profile renders its follower count the way a really-grown server would.
Repo.query!(
  """
  INSERT INTO account_stats (account_id, followers_count, following_count, statuses_count,
                             inserted_at, updated_at)
  SELECT target_account_id, count(*), 0, 0, now(), now()
  FROM follows GROUP BY target_account_id
  ON CONFLICT (account_id) DO UPDATE SET followers_count = EXCLUDED.followers_count
  """,
  []
)

Repo.query!(
  """
  INSERT INTO account_stats (account_id, followers_count, following_count, statuses_count,
                             inserted_at, updated_at)
  SELECT account_id, 0, count(*), 0, now(), now()
  FROM follows GROUP BY account_id
  ON CONFLICT (account_id) DO UPDATE SET following_count = EXCLUDED.following_count
  """,
  []
)

# The existing posts, written through the same door a real post goes through,
# so the follower feeds are filled the way they would really be filled.
Enum.each(Dataset.statuses(profile), fn text ->
  {:ok, _status} =
    Statuses.create_status(%{account_id: subject.id, text: text, visibility: :public})
end)

# The last follower needs a token of its own, because the fan-out measurement
# is "how long until the last person can see the post" and there is no way to
# ask that question with somebody else's credentials.
last_handle = Dataset.handle(seeded)
last = Accounts.lookup(last_handle)

# Already there: every follower was given one above. Fetched rather than
# created, because creating it a second time collides on the unique email.
last_user = Repo.get_by!(Abuuba.Accounts.User, account_id: last.id)

{:ok, _last_token, last_raw_token} =
  Abuuba.OAuth.issue_token(application, last_user, ["read", "write"])

Logger.info("seeded #{seeded} followers and #{length(Dataset.statuses(profile))} posts")

IO.puts("SEEDED #{subject.id}")
IO.puts("TOKEN #{raw_token}")
IO.puts("FOLLOWER_TOKEN #{last_raw_token}")
