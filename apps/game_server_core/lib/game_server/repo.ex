defmodule GameServer.Repo do
  # The adapter must be present at compile time for Ecto.Repo's supervisor
  # initialization. Read the adapter from the application configuration
  # (config/config.exs and environment-specific files). This keeps the
  # logic out of the module and avoids reading System.env directly here.

  # Use compile-time access so the adapter selection is fixed at compile time
  # and picked up from the config files.
  repo_conf = Application.compile_env(:game_server_core, __MODULE__, []) || []
  @adapter Keyword.get(repo_conf, :adapter, Ecto.Adapters.SQLite3)

  use Ecto.Repo,
    otp_app: :game_server_core,
    adapter: @adapter

  @doc ~S"""
  Escapes `LIKE` wildcards (`%`, `_`) and the escape character (`\`) in
  user-supplied search input so it matches literally.

  Queries must pair the escaped pattern with an explicit escape clause,
  because SQLite (unlike Postgres) has no default `LIKE` escape character:

      fragment("? LIKE ? ESCAPE '\\'", u.name, ^("%" <> Repo.escape_like(term) <> "%"))
  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(str) when is_binary(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
