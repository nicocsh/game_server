defmodule Mix.Tasks.Host.Proto.Gen do
  @moduledoc """
  Generates protobuf bindings for every target from a `.proto` file.

  A gamend protobuf schema is consumed by three runtimes — the Elixir plugin,
  the JavaScript client and the Godot client — each with its own generator.
  Running them by hand means three commands with different flag conventions,
  and a downstream game has no copy of this repo's shell scripts. This task
  ships with `game_server_core`, so any host application or plugin can run it.

  ## Usage

      mix host.proto.gen                    # every discovered .proto
      mix host.proto.gen path/to/my.proto   # just this one

  ## Options

      --only elixir,js,godot   Restrict targets (default: all available)
      --elixir-out DIR         Elixir output dir     (default: <plugin>/lib)
      --js-out FILE            JavaScript output     (default: <plugin>/clients/<name>.pb.js)
      --godot-out FILE         Godot output          (default: <plugin>/godot/<name>_pb.gd)

  ## Requirements

  Each target is skipped with a note when its toolchain is absent, so a project
  that only ships an Elixir plugin needs nothing extra:

    * Elixir — `protoc` plus `protoc-gen-elixir` (`mix escript.install hex protobuf`)
    * JavaScript — `npx` (fetches `protobufjs-cli` on demand)
    * Godot — `GODOT_BIN` and `GODOBUF_DIR` environment variables

  Discovery looks in `proto/`, `modules/plugins/*/proto/` and
  `modules/plugins_examples/*/proto/`, which covers the server itself and the
  plugin layout used by gamend games.
  """
  use Mix.Task

  alias GameServer.Proto.GodobufPresence

  @shortdoc "Generate protobuf bindings (Elixir, JS, Godot) from .proto files"

  @search_globs [
    "proto/*.proto",
    "modules/plugins/*/proto/*.proto",
    "modules/plugins_examples/*/proto/*.proto"
  ]

  @targets ~w(elixir js godot)

  @impl Mix.Task
  def run(args) do
    {opts, files} =
      OptionParser.parse!(args,
        strict: [only: :string, elixir_out: :string, js_out: :string, godot_out: :string]
      )

    targets = parse_targets(opts[:only])

    case files_to_generate(files) do
      [] ->
        Mix.shell().info("No .proto files found in: #{Enum.join(@search_globs, ", ")}")

      protos ->
        Enum.each(protos, &generate(&1, targets, opts))
    end
  end

  defp parse_targets(nil), do: @targets

  defp parse_targets(only) do
    requested = only |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    case requested -- @targets do
      [] -> requested
      unknown -> Mix.raise("unknown --only target(s): #{Enum.join(unknown, ", ")}")
    end
  end

  defp files_to_generate([]), do: Enum.flat_map(@search_globs, &Path.wildcard/1)

  defp files_to_generate(files) do
    Enum.map(files, fn file ->
      if File.exists?(file), do: file, else: Mix.raise("no such proto file: #{file}")
    end)
  end

  defp generate(proto, targets, opts) do
    Mix.shell().info("\n#{proto}")
    if "elixir" in targets, do: gen_elixir(proto, opts)
    if "js" in targets, do: gen_js(proto, opts)
    if "godot" in targets, do: gen_godot(proto, opts)
  end

  # ── Elixir ──────────────────────────────────────────────────────────────

  defp gen_elixir(proto, opts) do
    out = opts[:elixir_out] || Path.join(plugin_root(proto), "lib")

    cond do
      is_nil(System.find_executable("protoc")) ->
        skip("elixir", "protoc not on PATH")

      is_nil(protoc_gen_elixir()) ->
        skip("elixir", "protoc-gen-elixir not found (mix escript.install hex protobuf)")

      true ->
        File.mkdir_p!(out)
        env = [{"PATH", "#{Path.dirname(protoc_gen_elixir())}:#{System.get_env("PATH")}"}]

        cmd(
          "protoc",
          ["--elixir_out=#{out}", "-I", Path.dirname(proto), proto],
          env,
          "elixir",
          out
        )
    end
  end

  defp protoc_gen_elixir do
    System.find_executable("protoc-gen-elixir") ||
      [System.user_home(), ".mix", "escripts", "protoc-gen-elixir"]
      |> Path.join()
      |> then(&if File.exists?(&1), do: &1)
  end

  # ── JavaScript ──────────────────────────────────────────────────────────

  defp gen_js(proto, opts) do
    out = opts[:js_out] || Path.join([plugin_root(proto), "clients", "#{base(proto)}.pb.js"])

    if System.find_executable("npx") do
      File.mkdir_p!(Path.dirname(out))

      args =
        ~w(-p protobufjs-cli pbjs -t static-module -w es6 --keep-case --no-create --no-verify
           --no-delimited -o) ++ [out, proto]

      cmd("npx", args, [], "js", out)
    else
      skip("js", "npx not on PATH")
    end
  end

  # ── Godot ───────────────────────────────────────────────────────────────

  defp gen_godot(proto, opts) do
    out = opts[:godot_out] || Path.join([plugin_root(proto), "godot", "#{base(proto)}_pb.gd"])
    godot = System.get_env("GODOT_BIN")
    godobuf = System.get_env("GODOBUF_DIR")

    cond do
      is_nil(godot) or is_nil(godobuf) ->
        skip("godot", "set GODOT_BIN and GODOBUF_DIR (github.com/oniksan/godobuf)")

      not File.exists?(Path.join(godobuf, "addons/godobuf/godobuf_cmdln.gd")) ->
        skip("godot", "GODOBUF_DIR does not look like a godobuf checkout")

      true ->
        File.mkdir_p!(Path.dirname(out))
        args = ~w(--headless -s addons/godobuf/godobuf_cmdln.gd)
        args = args ++ ["--input=#{Path.expand(proto)}", "--output=#{Path.expand(out)}"]

        case System.cmd(godot, args, cd: godobuf, stderr_to_stdout: true) do
          {_output, 0} ->
            # godobuf's proto3-optional presence checks are wrong; see the module.
            rewritten = GodobufPresence.fix_file!(out)
            Mix.shell().info("  godot   #{out} (#{rewritten} presence checks fixed)")

          {output, code} ->
            Mix.shell().error("  godot   FAILED (#{code})\n#{output}")
        end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp cmd(exe, args, env, label, out) do
    case System.cmd(exe, args, env: env, stderr_to_stdout: true) do
      {_output, 0} -> Mix.shell().info("  #{String.pad_trailing(label, 7)} #{out}")
      {output, code} -> Mix.shell().error("  #{label} FAILED (#{code})\n#{output}")
    end
  end

  defp skip(label, reason),
    do: Mix.shell().info("  #{String.pad_trailing(label, 7)} skipped — #{reason}")

  defp base(proto), do: proto |> Path.basename(".proto")

  # A proto usually lives at <plugin>/proto/x.proto; outputs go next to the
  # plugin rather than next to the proto file itself.
  defp plugin_root(proto) do
    dir = Path.dirname(proto)
    if Path.basename(dir) == "proto", do: Path.dirname(dir), else: dir
  end
end
