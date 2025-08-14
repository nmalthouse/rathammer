#!/bin/bash

echo "run this script from the repo directory not distrib/"

RATOUT=distrib/appimagebuild


rm -rf "$RATOUT"
mkdir "$RATOUT"

zig build -Doptimize=ReleaseSafe -Dcpu=x86_64

cp zig-out/bin/rathammer "$RATOUT"
cp zig-out/bin/jsonmaptovmf "$RATOUT"
cp zig-out/bin/mapbuilder "$RATOUT"
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

# Copyright stuff
cp ratgraph/c_libs/libspng/LICENSE "$RATOUT"/SPNG_LICENSE
cp LICENSE "$RATOUT"/LICENSE

cd distrib
zip -r rathammer_linux_x86_x64.zip appimagebuild
cd ..
