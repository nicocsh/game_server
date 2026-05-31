defmodule GameServerWeb.PayloadDeltaTest do
  use ExUnit.Case, async: true

  alias GameServerWeb.PayloadDelta

  test "payload_delta returns nested updates and removes" do
    old = %{
      id: 1,
      metadata: %{
        "game_state" => "playing",
        "game_ends_at" => 123,
        "boat_adventure" => %{
          "hp" => 10,
          "coins_collected" => 0,
          "stopped_until" => 500
        }
      }
    }

    new = %{
      id: 1,
      metadata: %{
        "game_state" => "ended",
        "boat_adventure" => %{
          "hp" => 8,
          "coins_collected" => 2
        },
        "winner_user_id" => 42
      },
      player_count: 2
    }

    delta = PayloadDelta.payload_delta(old, new)

    assert delta == %{
             id: 1,
             u: %{
               metadata: %{
                 "game_state" => "ended",
                 "boat_adventure" => %{
                   "hp" => 8,
                   "coins_collected" => 2
                 },
                 "winner_user_id" => 42
               },
               player_count: 2
             },
             r: %{
               metadata: %{
                 "game_ends_at" => true,
                 "boat_adventure" => %{"stopped_until" => true}
               }
             }
           }

    assert apply_delta(old, delta) == new
  end

  test "payload_delta replaces changed lists" do
    old = %{id: 1, metadata: %{"unit_ids" => [1, 2, 3]}}
    new = %{id: 1, metadata: %{"unit_ids" => [1, 2, 3, 4]}}

    delta = PayloadDelta.payload_delta(old, new)

    assert delta == %{id: 1, u: %{metadata: %{"unit_ids" => [1, 2, 3, 4]}}}
    assert apply_delta(old, delta) == new
  end

  test "payload_delta preserves payload keys" do
    old = %{id: 1, boat_adventure: %{hp: 10}}
    new = %{id: 1, boat_adventure: %{hp: 8}}

    assert PayloadDelta.payload_delta(old, new) == %{id: 1, u: %{boat_adventure: %{hp: 8}}}
  end

  test "payload_delta diffs metadata like any other field" do
    old = %{
      id: 1,
      title: "Old",
      metadata: %{"game_state" => "playing", "old_key" => true},
      linked_providers: %{google: false}
    }

    new = %{
      id: 1,
      title: "New",
      metadata: %{"game_state" => "ended"},
      linked_providers: %{google: true}
    }

    delta = PayloadDelta.payload_delta(old, new)

    assert delta == %{
             id: 1,
             u: %{
               title: "New",
               metadata: %{"game_state" => "ended"},
               linked_providers: %{google: true}
             },
             r: %{metadata: %{"old_key" => true}}
           }

    assert apply_delta(old, delta) == new
  end

  test "payload_delta returns nil for no changes" do
    payload = %{id: 1, metadata: %{"boat_adventure" => %{"hp" => 10, "stopped_until" => nil}}}

    assert PayloadDelta.payload_delta(payload, payload) == nil
  end

  defp apply_delta(payload, nil), do: payload

  defp apply_delta(payload, delta) do
    payload
    |> Map.merge(Map.take(delta, [:id, "id", :user_id, "user_id"]))
    |> apply_updates(delta[:u] || %{})
    |> apply_removes(delta[:r] || %{})
  end

  defp apply_updates(payload, updates) do
    Map.merge(payload, updates, fn _key, old_value, new_value ->
      if is_map(old_value) and is_map(new_value) do
        apply_updates(old_value, new_value)
      else
        new_value
      end
    end)
  end

  defp apply_removes(payload, removes) do
    Enum.reduce(removes, payload, fn
      {key, true}, acc ->
        Map.delete(acc, key)

      {key, nested_removes}, acc when is_map(nested_removes) ->
        Map.update(acc, key, %{}, &apply_removes(&1, nested_removes))

      {_key, _value}, acc ->
        acc
    end)
  end
end
