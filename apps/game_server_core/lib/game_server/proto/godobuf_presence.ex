defmodule GameServer.Proto.GodobufPresence do
  @moduledoc """
  Fixes proto3-optional presence checks in godobuf-generated GDScript.

  godobuf emits scalar `has_x()` as `value != null`, but scalar fields are
  initialised to their type default and are never nil, so an absent optional
  field reads as present-with-default. The decoder does track real presence via
  `data[tag].state == FILLED` (godobuf itself uses that for oneof fields), so
  every null-check `has_x()` body is rewritten to the state check.

  Ported from `clients/fix_godobuf_presence.py` so `mix host.proto.gen` is
  self-contained for downstream projects, which do not have that script.
  """

  @field_decl ~r/^\t+__(\w+) = PBField\.new\("\1", PB_DATA_TYPE\.\w+, PB_RULE\.\w+, (\d+),/
  @has_func ~r/^(\t+)func has_(\w+)\(\) -> bool:$/

  @doc """
  Rewrites the file in place. Returns the number of `has_()` bodies changed.
  """
  @spec fix_file!(Path.t()) :: non_neg_integer()
  def fix_file!(path) do
    {contents, rewritten} = path |> File.read!() |> fix()
    File.write!(path, contents)
    rewritten
  end

  @doc "Rewrites GDScript source, returning `{source, rewritten_count}`."
  @spec fix(String.t()) :: {String.t(), non_neg_integer()}
  def fix(source) do
    {lines, rewritten} = source |> String.split("\n") |> walk(%{}, [], 0)
    {Enum.join(lines, "\n"), rewritten}
  end

  defp walk([], _tags, out, rewritten), do: {Enum.reverse(out), rewritten}

  defp walk([line | rest], tags, out, rewritten) do
    case Regex.run(@field_decl, line) do
      [_, name, tag] ->
        walk(rest, Map.put(tags, name, tag), [line | out], rewritten)

      nil ->
        maybe_rewrite_has(line, rest, tags, out, rewritten)
    end
  end

  defp maybe_rewrite_has(line, rest, tags, out, rewritten) do
    with [_, indent, name] <- Regex.run(@has_func, line),
         {:ok, tag} <- Map.fetch(tags, name),
         [null_check, true_line, false_line | tail] <- rest,
         true <- null_body?(null_check, true_line, false_line, name) do
      body = "#{indent}\treturn data[#{tag}].state == PB_SERVICE_STATE.FILLED"
      walk(tail, tags, [body, line | out], rewritten + 1)
    else
      _ -> walk(rest, tags, [line | out], rewritten)
    end
  end

  defp null_body?(null_check, true_line, false_line, name) do
    String.trim(null_check) == "if __#{name}.value != null:" and
      String.trim(true_line) == "return true" and
      String.trim(false_line) == "return false"
  end
end
