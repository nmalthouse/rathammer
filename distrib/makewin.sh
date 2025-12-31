#!/bin/bash
RATOUT=distrib/rathammer-windows

rm -rf "$RATOUT"
mkdir "$RATOUT"

# version must be >= win10_rs4
# win10_rs4 added support for unix domain sockets.
zig build -Doptimize=ReleaseFast -Dcpu=x86_64 -Dtarget=x86_64-windows.win10_rs4-gnu -Dcommit_hash=$(git rev-parse HEAD) -Dhttp_version_check=true
cp zig-out/bin/rathammer.exe "$RATOUT"
cp zig-out/bin/jsonmaptovmf.exe "$RATOUT"
cp zig-out/bin/mapbuilder.exe "$RATOUT"
cp zig-out/bin/ratremote.exe "$RATOUT"
cp -r ratasset "$RATOUT"
cp  config.vdf "$RATOUT"
cp -r doc "$RATOUT"

mkdir "$RATOUT"/ratgraph
cp -r ratgraph/asset "$RATOUT"/ratgraph

rm "$RATOUT"/ratgraph/asset/fonts/*

LOUT="$RATOUT"


cp -r rat_custom "$RATOUT"

cp -r games "$RATOUT"/games
cp -r extra "$RATOUT"/extra

# Copyright stuff
cp extra/thirdparty_legal.txt "$RATOUT"/thirdparty_legal.txt
cp LICENSE "$RATOUT"/LICENSE
cp README.md "$RATOUT"/README.md
cp extra/antivirus.txt "$RATOUT"/WINDOWS_USERS_README.txt

cd distrib
zip -r rathammer_windows.zip rathammer-windows
cd ..
