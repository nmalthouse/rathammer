#!/bin/bash

# the following env vars are available
#                       example path
# rh_cwd_path       -> .local/share/steam/steamapps/common
# rh_gamename       -> hl2_complete,portal,gmod, etc
# rh_gamedir        -> "/home/user/steam/steamapps/common/Half-Life 2"  absolute path
# rh_exedir         -> "Half-Life 2/bin"                                absolute path
# rh_outputdir      -> "Half-Life 2/hl2/maps                            absolute path
# rh_vmf            -> "mymap.vmf"                                      located in the working dir "/tmp/mapcompile"

echo "hello from the compile script!"

# strip the vmf extension
#mapname=$(basename $rh_vmf) 
mapname="${rh_vmf%.*}"

wine "$rh_gamedir"/bin/vbsp.exe -game "$rh_gamedir"/"$rh_gamename"  -novconfig $mapname
wine "$rh_gamedir"/bin/vvis.exe -game "$rh_gamedir"/"$rh_gamename"  -novconfig $mapname
wine "$rh_gamedir"/bin/vrad.exe -game "$rh_gamedir"/"$rh_gamename"  -novconfig $mapname
cp "$mapname".bsp "$rh_outputdir"/"$mapname".bsp
