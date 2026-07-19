defmodule Mix.Tasks.Host.Migrate do
  use Mix.Task

  @moduledoc false

  @shortdoc "Runs core and host migrations"

  alias GameServer.Repo.MigrationPaths
  alias Mix.Tasks.Ecto.Migrate

  @impl Mix.Task
  def run(args) do
    Migrate.run(MigrationPaths.as_args(ensure_host: true) ++ args)
  end
end
