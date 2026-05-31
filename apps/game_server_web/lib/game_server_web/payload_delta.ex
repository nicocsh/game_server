defmodule GameServerWeb.PayloadDelta do
  @moduledoc false

  defguardp is_plain_map(value) when is_map(value) and not is_struct(value)

  @identity_keys [:id, "id", :user_id, "user_id"]

  @spec payload_delta(map() | nil, map()) :: nil | map()
  def payload_delta(nil, new_payload), do: new_payload

  def payload_delta(old_payload, new_payload) when old_payload === new_payload, do: nil

  def payload_delta(old_payload, new_payload) when is_map(old_payload) and is_map(new_payload) do
    old_payload =
      old_payload
      |> normalize_root()
      |> drop_identity()

    new_diff_payload =
      new_payload
      |> normalize_root()
      |> drop_identity()

    if old_payload === new_diff_payload do
      nil
    else
      {updates, removes} = diff_maps(old_payload, new_diff_payload)

      case build_delta(updates, removes) do
        nil -> nil
        delta -> Map.merge(take_identity(new_payload), delta)
      end
    end
  end

  defp diff_maps(old_map, new_map) do
    old_map
    |> Map.keys()
    |> Kernel.++(Map.keys(new_map))
    |> MapSet.new()
    |> Enum.reduce({%{}, %{}}, fn key, {updates, removes} ->
      case {Map.fetch(old_map, key), Map.fetch(new_map, key)} do
        {:error, {:ok, new_value}} ->
          {Map.put(updates, key, normalize_payload(new_value)), removes}

        {{:ok, _old_value}, :error} ->
          {updates, Map.put(removes, key, true)}

        {{:ok, old_value}, {:ok, new_value}} ->
          case diff_value(old_value, new_value) do
            :unchanged ->
              {updates, removes}

            {:replace, value} ->
              {Map.put(updates, key, value), removes}

            {:nested, nested_updates, nested_removes} ->
              {
                put_if_not_empty(updates, key, nested_updates),
                put_if_not_empty(removes, key, nested_removes)
              }
          end
      end
    end)
  end

  defp diff_value(old_value, new_value) when old_value === new_value, do: :unchanged

  defp diff_value(old_value, new_value)
       when is_plain_map(old_value) and is_plain_map(new_value) do
    {updates, removes} = diff_maps(old_value, new_value)

    if updates == %{} and removes == %{} do
      :unchanged
    else
      {:nested, updates, removes}
    end
  end

  defp diff_value(old_value, new_value) do
    old_value = normalize_payload(old_value)
    new_value = normalize_payload(new_value)

    if old_value == new_value do
      :unchanged
    else
      {:replace, new_value}
    end
  end

  defp build_delta(updates, removes) when map_size(updates) == 0 and map_size(removes) == 0,
    do: nil

  defp build_delta(updates, removes) do
    %{}
    |> put_if_not_empty(:u, updates)
    |> put_if_not_empty(:r, removes)
  end

  defp put_if_not_empty(map, _key, value) when is_map(value) and map_size(value) == 0, do: map
  defp put_if_not_empty(map, key, value), do: Map.put(map, key, value)

  defp take_identity(payload) do
    payload
    |> Map.take(@identity_keys)
    |> normalize_payload()
  end

  defp drop_identity(payload), do: Map.drop(payload, @identity_keys)

  defp normalize_root(nil), do: %{}
  defp normalize_root(payload) when is_plain_map(payload), do: normalize_payload(payload)
  defp normalize_root(_payload), do: %{}

  defp normalize_payload(nil), do: nil

  defp normalize_payload(map) when is_plain_map(map) do
    Map.new(map, fn {key, value} -> {key, normalize_payload(value)} end)
  end

  defp normalize_payload(list) when is_list(list), do: Enum.map(list, &normalize_payload/1)

  defp normalize_payload(value), do: value
end
