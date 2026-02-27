# Changelog for v0.2.3
* Put jsonMapToVmf, ratremote, mapbuilder all into ratremote
* Auto complete for io targetname
* Remove support for vdf configs
* Remove support for inline game configs
* Fast Face tool snaps along normal when grid is consistent 
* Import multiple vmfs at once, one layer per vmf is created.
* Added default uv scale to gameinfo config
* Added locale support
* Auto load pointfile when map fails to compile
* Write config to appdata on Windows
* rewrite binding system, binds can now mask other binds, key repeat can be enabled per key, mouse buttons can be bound to any function
* !BREAKING Replace config.vdf and game vdf's with json. The old configs are ignored
* Snap primitive gen verticies to integer coordinates when size is above a threshold
* rewrote the gui layout system
* added tab buttons for workspace to menubar
