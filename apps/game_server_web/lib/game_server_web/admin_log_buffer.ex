defmodule GameServerWeb.AdminLogBuffer do
  @moduledoc """
  In-memory ring buffer of recent log entries for the admin dashboard.

  Entries are written directly into a public ETS `ordered_set` from the
  calling (logger handler) process, so logging never serializes through this
  GenServer — under a log storm writers stay concurrent and reads stay cheap.
  The GenServer only owns the table and trims it periodically.
  """

  use GenServer

  @name __MODULE__
  @table __MODULE__
  @topic "admin_logs"
  @max_entries 5000
  # Trim in batches instead of per insert; the buffer may briefly exceed
  # @max_entries by up to this amount.
  @trim_every 500

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def topic, do: @topic

  @doc """
  Appends a log entry. Called from the logger handler in the logging
  process — writes straight to ETS, no GenServer round-trip.
  """
  def put(entry) when is_map(entry) do
    if :ets.whereis(@table) != :undefined do
      entry = normalize_entry(entry)
      seq = :ets.update_counter(@table, :seq, 1, {:seq, 0})
      :ets.insert(@table, {seq, entry})

      if rem(seq, @trim_every) == 0 do
        GenServer.cast(@name, :trim)
      end

      Phoenix.PubSub.broadcast(GameServer.PubSub, @topic, {:admin_log, entry})
    end

    :ok
  end

  @doc "Returns buffered entries, newest first, with optional filters."
  def list(opts \\ []) do
    module_filter = Keyword.get(opts, :module)
    level_filter = Keyword.get(opts, :level)
    query_filter = Keyword.get(opts, :query)
    limit = Keyword.get(opts, :limit, @max_entries)

    entries()
    |> maybe_filter_module(module_filter)
    |> maybe_filter_level(level_filter)
    |> maybe_filter_query(query_filter)
    |> Enum.take(limit)
  end

  @doc "Returns a map of level => count for all buffered entries."
  def count_by_level do
    entries()
    |> Enum.group_by(& &1.level)
    |> Map.new(fn {level, entries} -> {level, length(entries)} end)
  end

  @doc "Returns the count of error/critical/alert/emergency entries in the last `seconds` seconds."
  def count_recent_errors(seconds \\ 3600) do
    cutoff = DateTime.add(DateTime.utc_now(), -seconds, :second)
    error_levels = [:error, :critical, :alert, :emergency]

    Enum.count(entries(), fn entry ->
      entry.level in error_levels and DateTime.compare(entry.timestamp, cutoff) == :gt
    end)
  end

  @impl true
  def init(_) do
    _ =
      :ets.new(@table, [
        :ordered_set,
        :public,
        :named_table,
        write_concurrency: true,
        read_concurrency: true
      ])

    _ = GameServerWeb.AdminLogHandler.install()
    _ = GameServerWeb.FileLogHandler.install()
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:trim, state) do
    case :ets.lookup(@table, :seq) do
      [{:seq, seq}] when seq > @max_entries ->
        # Delete all numeric keys at or below the cutoff (`:seq` is an atom
        # key and sorts after integers in an ordered_set, so it is untouched).
        cutoff = seq - @max_entries

        :ets.select_delete(@table, [
          {{:"$1", :_}, [{:is_integer, :"$1"}, {:"=<", :"$1", cutoff}], [true]}
        ])

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # Newest first: descending key order, skipping the :seq counter row.
  defp entries do
    @table
    |> :ets.select_reverse([{{:"$1", :"$2"}, [{:is_integer, :"$1"}], [:"$2"]}])
  rescue
    ArgumentError -> []
  end

  defp maybe_filter_module(entries, nil), do: entries
  defp maybe_filter_module(entries, ""), do: entries

  defp maybe_filter_module(entries, module_filter) when is_binary(module_filter) do
    filter = String.trim(module_filter)

    if filter == "" do
      entries
    else
      Enum.filter(entries, fn entry ->
        mod = entry.module

        mod_str =
          case mod do
            nil -> ""
            atom when is_atom(atom) -> Atom.to_string(atom)
            other -> to_string(other)
          end

        String.contains?(mod_str, filter)
      end)
    end
  end

  defp maybe_filter_level(entries, nil), do: entries
  defp maybe_filter_level(entries, ""), do: entries
  defp maybe_filter_level(entries, "all"), do: entries

  defp maybe_filter_level(entries, level) when is_binary(level) do
    atom_level = String.to_existing_atom(level)
    Enum.filter(entries, fn entry -> entry.level == atom_level end)
  rescue
    _ -> entries
  end

  defp maybe_filter_query(entries, nil), do: entries
  defp maybe_filter_query(entries, ""), do: entries

  defp maybe_filter_query(entries, query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        entries

      trimmed ->
        needle = String.downcase(trimmed)

        Enum.filter(entries, fn entry ->
          entry.message
          |> to_string()
          |> String.downcase()
          |> String.contains?(needle)
        end)
    end
  end

  defp normalize_entry(entry) do
    module =
      cond do
        is_atom(entry[:module]) -> entry[:module]
        is_tuple(entry[:mfa]) and tuple_size(entry[:mfa]) == 3 -> elem(entry[:mfa], 0)
        true -> nil
      end

    entry
    |> Map.put_new(:timestamp, DateTime.utc_now())
    |> Map.put(:module, module)
  end
end
