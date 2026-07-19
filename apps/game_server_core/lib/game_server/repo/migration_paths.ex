defmodule GameServer.Repo.MigrationPaths do
  @moduledoc """
  Resolves every migration directory that belongs to a gamend deployment.

  A host application (the umbrella's `game_server_host`, or a downstream game
  such as gamend_polyglot) runs **core migrations plus its own**, and core can
  be present either as an umbrella app or as a dependency. Anything that walks
  migrations — the `host.*` mix tasks, the admin runtime page — must consider
  the same set, so the list lives here rather than being copied per caller.
  """

  @candidates [
    "apps/game_server_core/priv/repo/migrations",
    "deps/game_server_core/priv/repo/migrations",
    "deps/game_server_core/apps/game_server_core/priv/repo/migrations",
    "priv/repo/migrations"
  ]

  @doc """
  Existing migration directories, absolute and de-duplicated.

  Pass `ensure_host: true` (the mix tasks do) to create the host's own
  `priv/repo/migrations` first, so Ecto does not fail on a missing path in a
  project that has not written a migration yet.
  """
  @spec all(keyword()) :: [String.t()]
  def all(opts \\ []) do
    if Keyword.get(opts, :ensure_host, false), do: File.mkdir_p!("priv/repo/migrations")

    [core_dep_path() | @candidates]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  @doc "The paths as `--migrations-path <dir>` arguments for the Ecto mix tasks."
  @spec as_args(keyword()) :: [String.t()]
  def as_args(opts \\ []) do
    opts |> all() |> Enum.flat_map(&["--migrations-path", &1])
  end

  # Only available under Mix (not in a release), so guard on the module.
  defp core_dep_path do
    with true <- Code.ensure_loaded?(Mix.Project),
         dep_path when is_binary(dep_path) <- Mix.Project.deps_paths()[:game_server_core] do
      Path.join(dep_path, "priv/repo/migrations")
    else
      _ -> nil
    end
  end
end
