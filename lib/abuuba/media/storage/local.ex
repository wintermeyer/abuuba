defmodule Abuuba.Media.Storage.Local do
  @moduledoc """
  Files on this machine's disk, served by the endpoint.

  The default, and the right answer for most servers: one BEAM application and
  one Postgres, with the pictures next to them.

  Every key is checked against the root before anything is written. The keys
  are derived from ids rather than from anything a stranger wrote, but a
  storage backend that trusts its caller is one bad caller away from writing
  anywhere on the disk, and the check costs a path expansion.
  """

  @behaviour Abuuba.Media.Storage

  alias Abuuba.Federation.URIs
  alias Abuuba.Media.Storage

  @doc """
  Where files are written.
  """
  @spec root() :: String.t()
  def root do
    Application.get_env(:abuuba, :media_root) || Path.join(System.tmp_dir!(), "abuuba-media")
  end

  @impl Storage
  def put(key, source_path, _opts) do
    with {:ok, path} <- resolve(key) do
      File.mkdir_p!(Path.dirname(path))

      case File.cp(source_path, path) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Storage
  def delete(key) do
    case resolve(key) do
      {:ok, path} -> File.rm(path)
      _ -> :ok
    end

    :ok
  end

  @impl Storage
  def exists?(key) do
    case resolve(key) do
      {:ok, path} -> File.exists?(path)
      _ -> false
    end
  end

  @impl Storage
  def url(key) do
    host = Storage.alias_host() || URIs.base_url()

    "#{host}/media/#{Storage.encode_key(key)}"
  end

  @impl Storage
  def local_path(key) do
    case resolve(key) do
      {:ok, path} -> path
      _ -> nil
    end
  end

  # Expanded and compared, so a key containing `..` is refused rather than
  # resolved somewhere outside the root.
  defp resolve(key) do
    root = Path.expand(root())
    path = Path.expand(Path.join(root, key))

    if path == root or String.starts_with?(path, root <> "/") do
      {:ok, path}
    else
      {:error, :bad_key}
    end
  end
end
