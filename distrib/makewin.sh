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

#cp libfreetype-6.dll $RATOUT
#cp SDL3.dll        $RATOUT
#cp libbz2-1.dll $RATOUT
#cp libbrotlidec.dll $RATOUT
#cp libharfbuzz-0.dll $RATOUT
#cp libpng16-16.dll $RATOUT
#cp zlib1.dll $RATOUT
#cp libbrotlicommon.dll $RATOUT
#cp libgcc_s_seh-1.dll $RATOUT
#cp libstdc++-6.dll $RATOUT
#cp libgraphite2.dll $RATOUT
#cp libglib-2.0-0.dll $RATOUT
#cp libintl-8.dll $RATOUT
#cp libwinpthread-1.dll $RATOUT
#cp libiconv-2.dll $RATOUT
#cp libpcre2-8-0.dll $RATOUT

cp -r rat_custom "$RATOUT"

# Copyright stuff
cp ratgraph/c_libs/libspng/LICENSE "$RATOUT"/SPNG_LICENSE
cp LICENSE "$RATOUT"/LICENSE
cp README.md "$RATOUT"/README.md
cp extra/antivirus.txt "$RATOUT"/antivirus.txt

cd distrib
zip -r rathammer_windows.zip rathammer-windows
cd ..
