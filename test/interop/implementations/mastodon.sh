# How to make an account on Mastodon and get a token for it.
#
# Every implementation needs three things from its file: a base URL, an
# account, and a token that can post as it. Everything after that is the client
# API, which all three of these implement.
#
# The commands here are Mastodon's own CLI. If one of them changes, this file
# is the only place that has to change — and the runner reports a failure to
# create an account as a skipped implementation rather than sixteen scenario
# failures, keeping what the CLI said in `results/raw/mastodon-setup.log`.

PEER_ID=mastodon
PEER_NAME="Mastodon"
PEER_DOMAIN=mastodon.interop
PEER_URL=http://localhost:${MASTODON_INTEROP_PORT:-3000}
PEER_ACCOUNT=interop

peer_create_account() {
  # Prints the account's access token on the last line, which is what tootctl
  # does when it creates an account with an app.
  docker compose -f "$COMPOSE" exec -T mastodon \
    bin/tootctl accounts create "$PEER_ACCOUNT" \
    --email "$PEER_ACCOUNT@$PEER_DOMAIN" --confirmed --approve --role Owner >/dev/null || true

  # A token to act as it. Created directly rather than through the OAuth dance,
  # because a browser is not available and the dance proves nothing here.
  docker compose -f "$COMPOSE" exec -T -e ACCOUNT="$PEER_ACCOUNT" mastodon bin/rails runner '
    account = Account.find_local(ENV.fetch("ACCOUNT"))
    application = Doorkeeper::Application.find_or_create_by!(name: "interop") do |app|
      app.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
      app.scopes = "read write follow admin:read"
    end
    token = Doorkeeper::AccessToken.create!(
      application: application,
      resource_owner_id: account.user.id,
      # `admin:read` so the suite can look at what moderation received: a
      # report forwarded from another server is only visible through the admin
      # API, and a scenario that cannot read it can only guess.
      scopes: "read write follow admin:read"
    )
    puts "INTEROP_TOKEN=#{token.token}"
  ' | grep -o 'INTEROP_TOKEN=.*' | cut -d= -f2
}

peer_version() {
  # From the running application rather than a file: the image has no
  # `.version`, which is why every report so far has said "unknown".
  docker compose -f "$COMPOSE" exec -T mastodon \
    bin/rails runner 'puts Mastodon::Version.to_s' 2>/dev/null | tail -1 |
    grep -E '^[0-9]' || echo "unknown"
}

# What Mastodon's own queues are doing, printed when an await gives up.
#
# The point is to tell whose slowness a red line is. abuuba's side already says
# whether its deliveries completed; when they have -- and on the one occurrence
# since this was instrumented, thirteen had, all on the first attempt -- the
# post was sent and the question moves to the other server. A Sidekiq queue
# with a thousand jobs behind the one that matters explains a two-minute wait
# without anything being broken.
#
# Counts alone were not enough. "retrying: 3" says a job failed and says
# nothing about why, and Sidekiq's own backoff is the same shape as ours --
# roughly `count**4 + 15` seconds -- so a job that has failed three times is
# past two minutes from its next attempt on its own, which is exactly the
# window a scenario gives up in. So the newest retry and the newest dead job
# are printed with their class, their arguments and the error they carry: that
# is the sentence that turns "the post never arrived" into a diagnosis.
peer_queue_state() {
  docker compose -f "$COMPOSE" exec -T mastodon bin/rails runner '
    require "sidekiq/api"

    sizes = Sidekiq::Queue.all.map { |q| [q.name, q.size] }.to_h

    puts "peer queues: #{sizes}"
    puts "peer scheduled: #{Sidekiq::ScheduledSet.new.size}, retrying: #{Sidekiq::RetrySet.new.size}, dead: #{Sidekiq::DeadSet.new.size}"

    describe = lambda do |label, job|
      next if job.nil?

      args = job.args.map { |a| a.to_s[0, 80] }.join(", ")
      error = [job["error_class"], job["error_message"].to_s[0, 200]].compact.join(": ")
      at = job.respond_to?(:at) && job.at ? job.at.utc.iso8601 : "?"

      puts "peer #{label}: #{job.klass} retry=#{job["retry_count"]} next=#{at} args=[#{args}] #{error}"
    end

    describe.call("newest retry", Sidekiq::RetrySet.new.to_a.last)
    describe.call("newest dead", Sidekiq::DeadSet.new.to_a.last)
  ' 2>/dev/null | grep -E "^peer (queues|scheduled|newest)"
}
