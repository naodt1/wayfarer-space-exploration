#!/bin/bash
# Prepares and bakes every downloaded model for the game (see README › Models by Jungle Jim)
set -u
cd "$(dirname "$0")/../.."
BL=/Applications/Blender.app/Contents/MacOS/Blender
N=SourceModels/new; P=SourceModels/prepped
job() {   # name src out_dir S tex [prep options...]
  local name=$1 src=$2 out=$3 S=$4 tex=$5; shift 5
  $BL -b -P Tools/blender/prep_prop.py -- "$N/$src" "$P/$name.blend" "$@" 2>&1 | grep -E "^PREP|Error|Traceback"
  $BL -b "$P/$name.blend" -P Tools/blender/export_ship.py -- "$out" "$name" "$S" "$tex" 2>&1 | grep -E "exported|emission|Error|Traceback"
}
job tower      brutalist_skyscraper_tower_by_jungle_jim.glb  Assets/Props 1 2048
job apartments cyberpunk_background_appartment_building.glb  Assets/Props 1 2048
job truck      cyberpunk_cargo_truck.glb                     Assets/Props 1 1024 tris=60000
job station    giant_round_spacestation_by_jungle_jim.glb    Assets/Props 1 2048 centre=middle
job computer   sci-fi_supercomputer.glb                      Assets/Props 1 2048
job citysphere sci-fi_city_material_texture_2k.glb           Assets/Props 1 2048 centre=middle
job robot      sci-fi_o.b._robot_unit_th-icc02_animated.glb  Assets/Props 1 1024 tris=40000 exclude=Icosphere
job chair1     sci-fi_chairs_x4_by_jungle_jim.glb            Assets/Props 1 1024 xrange=-0.5:0.4 scale=1.15
job chair2     sci-fi_chairs_x4_by_jungle_jim.glb            Assets/Props 1 1024 xrange=0.4:1.1 scale=1.15
job chair3     sci-fi_chairs_x4_by_jungle_jim.glb            Assets/Props 1 1024 xrange=1.1:1.8 scale=1.15
job chair4     sci-fi_chairs_x4_by_jungle_jim.glb            Assets/Props 1 1024 xrange=1.8:2.6 scale=1.15
job heron      heron_spaceship_v2_animated.glb               Assets/Ships 18.5714 2048 exclude=Plane length=26 centre=middle rotz=180
job corridor   spaceship_corridor_by_jungle_jim.glb          Assets/Props 1 4096 tris=150000
job hallway    spaceship_corridorhallway.glb                 Assets/Props 1 2048 scale=1.5 tris=80000 openends=2.0
echo BATCH DONE
