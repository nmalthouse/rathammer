#!/bin/bash
RATOUT=distrib/rathammer-windows

rm -rf "$RATOUT"
mkdir "$RATOUT"

zig build -Doptimize=ReleaseSafe -Dcpu=x86_64 -Dtarget=x86_64-windows-gnu -Dcommit_hash=$(git rev-parse HEAD) -Dhttp_version_check=true
cp zig-out/bin/rathammer.exe "$RATOUT"
cp zig-out/bin/jsonmaptovmf.exe "$RATOUT"
cp zig-out/bin/mapbuilder.exe "$RATOUT"
cp -r ratasset "$RATOUT"
cp  config.vdf "$RATOUT"
cp -r doc "$RATOUT"

mkdir "$RATOUT"/ratgraph
cp -r ratgraph/asset "$RATOUT"/ratgraph

rm "$RATOUT"/ratgraph/asset/fonts/*

LOUT="$RATOUT"


cp -r rat_custom "$RATOUT"

# Copyright stuff
cp extra/thirdparty_legal.txt "$RATOUT"/thirdparty_legal.txt
cp LICENSE "$RATOUT"/LICENSE
cp README.md "$RATOUT"/README.md
cp extra/antivirus.txt "$RATOUT"/antivirus.txt

cd distrib
zip -r rathammer_windows.zip rathammer-windows
cd ..
