defmodule GameServer.LobbySnapshots.Blob do
  @moduledoc """
  Content-addressed storage for one snapshot section.

  The hash is the primary key, so identical content stores a single row however
  many sections, snapshots or lobbies reference it. This subsumes per-section
  change detection: an unchanged section hashes to the value already stored.

  `last_referenced_at` is what retention prunes on — see the migration for why
  `inserted_at` cannot be used for that.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:hash, :string, autogenerate: false}
  schema "lobby_snapshot_blobs" do
    field :content, :map
    field :byte_size, :integer
    field :last_referenced_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(blob, attrs) do
    blob
    |> cast(attrs, [:hash, :content, :byte_size, :last_referenced_at])
    |> validate_required([:hash, :content, :byte_size, :last_referenced_at])
  end
end
