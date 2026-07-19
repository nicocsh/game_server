defmodule Mix.Tasks.Host.Rollback do
  use Mix.Task

  @moduledoc false

  @shortdoc "Rolls back core and host migrations"

  alias GameServer.Repo.MigrationPaths
  alias Mix.Tasks.Ecto.Rollback

  @impl Mix.Task
  def run(args) do
    Rollback.run(MigrationPaths.as_args(ensure_host: true) ++ args)
  end
end
