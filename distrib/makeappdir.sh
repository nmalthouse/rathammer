#!/bin/bash

echo "run this script from the repo directory not distrib/"

RATOUT=distrib/appimagebuild


rm -rf "$RATOUT"
mkdir "$RATOUT"

zig build -Doptimize=ReleaseSafe -Dcpu=x86_64 -Dcommit_hash=$(git rev-parse HEAD) -Dhttp_version_check=true

cp zig-out/bin/rathammer "$RATOUT"
#cp zig-out/bin/jsonmaptovmf "$RATOUT"
cp zig-out/bin/ratremote "$RATOUT"
cp -r ratasset "$RATOUT"
cp  config.vdf "$RATOUT"
cp -r doc "$RATOUT"

#cp -r ratgraph "$RATOUT"
mkdir "$RATOUT"/ratgraph
cp -r ratgraph/asset "$RATOUT"/ratgraph

# the fonts are too big 
rm "$RATOUT"/ratgraph/asset/fonts/*

cp distrib/appimageskeleton/* "$RATOUT"/

cp -r rat_custom "$RATOUT"

cp -r games "$RATOUT"/games
cp -r extra "$RATOUT"/extra

# Copyright stuff
cp extra/thirdparty_legal.txt "$RATOUT"/thirdparty_legal.txt
cp LICENSE "$RATOUT"/LICENSE
cp README.md "$RATOUT"/README.md

cd distrib
zip -r rathammer_linux_x86_x64.zip appimagebuild
cd ..
