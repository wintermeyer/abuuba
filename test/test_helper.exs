# Tests that shell out to ffmpeg are skipped where it is not installed, and
# only there. A contributor without it can still run the rest of the suite; CI
# installs it, so nothing is quietly skipped in the place that has to catch a
# broken pipeline.
exclude = if Abuuba.Media.FFmpeg.available?(), do: [], else: [needs_ffmpeg: true]

if exclude != [] do
  IO.puts("ffmpeg not found: skipping the media tests that need it")
end

# `max_cases` is derived from the Repo pool_size rather than restated, so async
# tests never queue on a connection that cannot exist and the two cannot drift
# apart.
ExUnit.start(
  max_cases: :abuuba |> Application.fetch_env!(Abuuba.Repo) |> Keyword.fetch!(:pool_size),
  exclude: exclude
)

Ecto.Adapters.SQL.Sandbox.mode(Abuuba.Repo, :manual)
