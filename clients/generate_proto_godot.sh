#!/usr/bin/env bash
# Thin wrapper kept for muscle memory: the real implementation is the shared
# `mix host.proto.gen` task in game_server_core, which downstream games can run
# too (this script is not shipped with the package).
#
# Requires GODOT_BIN and GODOBUF_DIR (see the task's docs).
#
#   generate_proto_godot.sh                       # built-in realtime schema
#   generate_proto_godot.sh in.proto out_pb.gd    # a game's own schema
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ "$#" -eq 2 ]; then
  mix host.proto.gen --only godot --godot-out "$2" "$1"
  exit 0
fi

TEMPLATE="clients/gamend_template/proto/gamend_realtime_pb.gd"
mix host.proto.gen --only godot --godot-out "$TEMPLATE" proto/gamend_realtime.proto

# The addon copy used for local development tracks the template.
ADDONS="godot_addons/addons/gamend/proto/gamend_realtime_pb.gd"
mkdir -p "$(dirname "$ADDONS")"
cp "$TEMPLATE" "$ADDONS"
echo "Godot protobuf bindings regenerated."
