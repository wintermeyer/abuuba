defmodule Abuuba.CacheTest do
  # `async: false` because these tests flip the global `cache_enabled` switch
  # that every other test relies on being off.
  use ExUnit.Case, async: false

  alias Abuuba.Cache

  setup do
    Application.put_env(:abuuba, :cache_enabled, true)
    on_exit(fn -> Application.put_env(:abuuba, :cache_enabled, false) end)

    %{key: make_ref()}
  end

  test "computes once and serves the kept value after", %{key: key} do
    counter = :counters.new(1, [])

    compute = fn ->
      :counters.add(counter, 1, 1)
      :value
    end

    assert Cache.fetch(key, 60_000, compute) == :value
    assert Cache.fetch(key, 60_000, compute) == :value
    assert :counters.get(counter, 1) == 1
  end

  test "does not keep a nil, because nothing-yet must not become sticky", %{key: key} do
    # The instance signing key is read through here, and it is nil for the
    # moment between an actor existing and its keypair existing. Keeping that
    # nil for the TTL would mean every outbound request going unsigned for five
    # minutes, which is a thing that has happened here before and is invisible
    # from the outside: deliveries keep leaving and every peer refuses them.
    counter = :counters.new(1, [])

    compute = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) < 3, do: nil, else: :ready
    end

    assert Cache.fetch(key, 60_000, compute) == nil
    assert Cache.fetch(key, 60_000, compute) == nil
    assert Cache.fetch(key, 60_000, compute) == :ready

    # And once there is something to keep, it is kept.
    assert Cache.fetch(key, 60_000, compute) == :ready
    assert :counters.get(counter, 1) == 3
  end

  test "recomputes after the entry expires", %{key: key} do
    counter = :counters.new(1, [])
    compute = fn -> :counters.add(counter, 1, 1) end

    Cache.fetch(key, 0, compute)
    Process.sleep(1)
    Cache.fetch(key, 0, compute)

    assert :counters.get(counter, 1) == 2
  end

  test "invalidation drops the entry", %{key: key} do
    Cache.fetch(key, 60_000, fn -> :old end)
    :ok = Cache.invalidate(key)

    assert Cache.fetch(key, 60_000, fn -> :new end) == :new
  end

  test "does not keep anything while disabled", %{key: key} do
    Application.put_env(:abuuba, :cache_enabled, false)

    assert Cache.fetch(key, 60_000, fn -> :first end) == :first
    assert Cache.fetch(key, 60_000, fn -> :second end) == :second
  end
end

defmodule Abuuba.CacheInvalidationTest do
  # The suite runs with the cache off so async tests stay isolated; this file
  # turns it on to prove the write paths actually drop what they cached — a
  # forgotten invalidation would otherwise only ever fail in production.
  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Settings

  setup do
    Application.put_env(:abuuba, :cache_enabled, true)
    Abuuba.Cache.invalidate({:setting, "site_title"})

    on_exit(fn ->
      Application.put_env(:abuuba, :cache_enabled, false)
      Abuuba.Cache.invalidate({:setting, "site_title"})
    end)
  end

  test "a setting written through `put/2` is served fresh, not from the cache" do
    :ok = Settings.put("site_title", "Before")
    assert Settings.get("site_title") == "Before"

    :ok = Settings.put("site_title", "After")

    assert Settings.get("site_title") == "After"
  end

  test "an uploaded emoji appears without waiting for the TTL" do
    Abuuba.Cache.invalidate(:custom_emojis)
    on_exit(fn -> Abuuba.Cache.invalidate(:custom_emojis) end)

    assert Abuuba.Instance.custom_emojis() == []

    {:ok, _} =
      Abuuba.Instance.put_custom_emoji(%{shortcode: "wave", image_url: "/emoji/wave.png"})

    assert [%{shortcode: "wave"}] = Abuuba.Instance.custom_emojis()
  end

  test "a new rule appears, and a retired one disappears, without waiting" do
    Abuuba.Cache.invalidate(:server_rules)
    on_exit(fn -> Abuuba.Cache.invalidate(:server_rules) end)

    assert Settings.rules() == []

    {:ok, rule} = Settings.create_rule(%{text: "Be kind."})
    assert [%{text: "Be kind."}] = Settings.rules()

    {:ok, _} = Settings.delete_rule(rule)
    assert Settings.rules() == []
  end

  test "rotating the instance keypair changes what outbound requests sign with" do
    Abuuba.Cache.invalidate(:instance_signing_key)
    on_exit(fn -> Abuuba.Cache.invalidate(:instance_signing_key) end)

    actor = InstanceActor.fetch!()
    {_key_id, before_key} = InstanceActor.signing_key()

    {:ok, _} = Accounts.rotate_keypair(actor)

    {_key_id, after_key} = InstanceActor.signing_key()

    refute before_key == after_key
  end
end
