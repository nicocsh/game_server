defmodule GameServer.LobbySnapshots.Snapshot do
  @moduledoc """
  One capture of a lobby's state at a mutation entry point.

  `section_hashes` maps section name to a `Blob` hash; the blobs hold the
  content. Sections whose content did not change resolve to the hash already
  stored, so an unchanged section costs one map entry and no blob row.

  Ordered by `(inserted_at, id)` — `id` is UUIDv7 and therefore time-ordered, so
  it breaks ties without a stored counter. `lobby_id` has no foreign key. See
  the migration for both.
  """

  use GameServer.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @sections ~w(lobby lobby_metadata members kv_lobby kv_user)

  schema "lobby_snapshots" do
    field :lobby_id, GameServer.UUIDv7
    field :trigger, :string
    field :section_hashes, :map, default: %{}
    field :flagged, :boolean, default: false

    belongs_to :user, GameServer.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec sections() :: [String.t()]
  def sections, do: @sections

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:lobby_id, :trigger, :section_hashes, :flagged, :user_id])
    |> validate_required([:lobby_id, :trigger])
    |> validate_length(:trigger, min: 1, max: 128)
    |> foreign_key_constraint(:user_id)
  end
end
