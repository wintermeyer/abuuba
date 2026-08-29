# Seeds the Mastodon side of a benchmark run.
#
# Run inside the web container:
#   docker compose exec -T web bin/rails runner /bench/seed/mastodon.rb small
#
# This writes exactly what bench/seed/abuuba.exs writes: the same handles in the
# same order, the same number of posts, the same text. The two scripts are the
# only reason the comparison means anything, so neither of them may invent
# anything the other does not.
#
# The naming and the counts are defined by Abuuba.Bench.Dataset and repeated here
# rather than shared, because there is no way to share code across two runtimes
# in two containers. bench/README.md says how to check they still agree.

# Must match Abuuba.Bench.Dataset. A size is a follower count, or one of four
# shorthand names kept because earlier results were recorded under them.
#
# Anything past a thousand followers carries 20 posts rather than 200, on
# purpose: the seeded work is followers x statuses, and 200 posts at a million
# followers is two hundred million feed rows, which is days of Sidekiq on this
# side. See the module doc there.
NAMED = {
  'small' => 1_000,
  'medium' => 10_000,
  'large' => 100_000,
  'huge' => 1_000_000
}.freeze
MANY_FOLLOWERS = 1_000
SUBJECT = 'benchsubject'

profile = ARGV[0] || 'small'
follower_count = profile.match?(/\A\d+\z/) ? profile.to_i : NAMED.fetch(profile)
statuses = follower_count > MANY_FOLLOWERS ? 20 : 200

def handle(index)
  format('bench%06d', index)
end

def text(index)
  "Benchmark post #{index}. " + ('The quick brown fox jumps over the lazy dog. ' * 3)
end

subject = Account.create!(username: SUBJECT, display_name: 'Benchmark subject')

# `save!(validate: false)`, not `create!`. In production Mastodon runs
# EmailMxValidator over a new user's address, which does a real DNS MX lookup:
# `bench.invalid` has no MX record, correctly, because .invalid is reserved for
# exactly this — so seeding died on "E-mail address does not seem to exist".
# The alternative is pointing the seed at a domain somebody really owns and
# sending its DNS a thousand lookups, which is worse.
user = User.new(
  account: subject,
  email: "#{SUBJECT}@bench.invalid",
  password: 'benchmark password',
  agreement: true,
  approved: true,
  confirmed_at: Time.now.utc,
  current_sign_in_at: Time.now.utc
)
user.save!(validate: false)

# `approved` has to be forced after the fact. Mastodon runs
# `before_create :set_approved`, which recomputes the column from the
# instance's registration mode — and a `before_create` callback runs even
# under `save(validate: false)`, so the `approved: true` above is overwritten
# with false on a server whose registrations are closed. The API then answers
# every authenticated read with 403 "Your login is currently pending
# approval", which is not a thing worth benchmarking.
user.update_columns(approved: true, confirmed_at: Time.now.utc, current_sign_in_at: Time.now.utc)
subject.reload

# In batches, for the same reason the other side does it: a hundred thousand
# rows one at a time is the benchmark measuring its own seeding.
(1..follower_count).each_slice(1_000) do |slice|
  now = Time.now.utc

  rows = slice.map do |index|
    { username: handle(index), display_name: handle(index), created_at: now, updated_at: now }
  end

  Account.insert_all(rows)
end

# Read back in slices. `Account.where(username: <a million strings>)` builds a
# single IN list, and Postgres takes at most 65535 bind parameters — the
# hundred-thousand profile already in the dataset would have failed on this
# line long before a million did. Nobody had run either.
accounts = []
(1..follower_count).each_slice(1_000) do |slice|
  handles = slice.map { |index| handle(index) }
  accounts.concat(Account.where(username: handles).pluck(:id, :username))
end
ids = accounts.map(&:first)

# A signed-in person behind every follower, matching what the abuuba seeder
# writes. Mastodon only fans out to local followers who have a user record and
# a recent `current_sign_in_at` (`followers_for_local_distribution` merges
# `User.signed_in_recently`); abuuba also delivers to followers with no user at
# all. Left as bare accounts, the same thousand followers meant a thousand
# deliveries on one server and none whatsoever on the other, and the fan-out
# comparison was measuring that difference rather than fan-out.
#
# `insert_all` also steps around the MX lookup, for the reason above.
accounts.each_slice(1_000) do |slice|
  now = Time.now.utc

  rows = slice.map do |id, username|
    {
      account_id: id,
      email: "#{username}@bench.invalid",
      approved: true,
      confirmed_at: now,
      current_sign_in_at: now,
      sign_in_count: 1,
      created_at: now,
      updated_at: now
    }
  end

  User.insert_all(rows)
end

ids.each_slice(1_000) do |slice|
  now = Time.now.utc

  rows = slice.map do |id|
    {
      account_id: id,
      target_account_id: subject.id,
      show_reblogs: true,
      notify: false,
      created_at: now,
      updated_at: now
    }
  end

  Follow.insert_all(rows)
end

# Through PostStatusService, so the follower feeds are filled the way they
# would really be filled — which is the thing being measured later.
(1..statuses).each do |index|
  PostStatusService.new.call(subject, text: text(index), visibility: :public)
end

# The measurements read a home timeline and make a post, both of which need a
# token. Printed rather than stored, the same as the other side.
application = Doorkeeper::Application.create!(
  name: 'benchmark',
  redirect_uri: 'urn:ietf:wg:oauth:2.0:oob',
  scopes: 'read write'
)

token = Doorkeeper::AccessToken.create!(
  application: application,
  resource_owner_id: subject.user.id,
  scopes: 'read write'
)

# The last follower needs a token of its own, for the same reason the other
# side gives it one: the fan-out measurement is "how long until the last person
# can see the post".
# Already there: every follower was given one above. Fetched rather than
# created, because creating it again collides on the unique email index.
last = Account.find_by!(username: handle(follower_count))
last_user = User.find_by!(account_id: last.id)

follower_token = Doorkeeper::AccessToken.create!(
  application: application,
  resource_owner_id: last_user.id,
  scopes: 'read write'
)

puts "SEEDED #{subject.id}"
puts "TOKEN #{token.token}"
puts "FOLLOWER_TOKEN #{follower_token.token}"
