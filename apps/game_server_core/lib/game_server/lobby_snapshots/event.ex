defmodule GameServer.LobbySnapshots.Event do
  @moduledoc """
  A decision worth explaining, recorded between two snapshots.

  Snapshots record *what* changed; they cannot record *why*. A snapshot shows
  `speed: 100 -> 50`; only an event carries the `gap` and `targets_ahead` that
  produced it.

  Which interval an event falls in is derived at read time by `timeline/1` —
  the latest snapshot at or before the event — rather than stored. See the
  migration.
  """

  use GameServer.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "lobby_events" do
    field :lobby_id, GameServer.UUIDv7
    field :kind, :string
    field :payload, :map, default: %{}

    belongs_to :user, GameServer.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:lobby_id, :kind, :payload, :user_id])
    |> validate_required([:lobby_id, :kind])
    |> validate_length(:kind, min: 1, max: 128)
    |> foreign_key_constraint(:user_id)
  end
end
