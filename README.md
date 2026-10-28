# Level editor for the Source Engine

![Screenshot of the editor](doc/screen_v0.4.0.jpg)

Rathammer is still in development, as such, it is missing many features, and some things are in a half finished state. Expect some bugs, and gui weirdness.

[Documentation](doc/start.md)

[Bug Tracker](https://todo.sr.ht/~niklasm/rathammer)

## Installing on Windows
1. [Download](https://github.com/nmalthouse/rathammer/releases)
1. Unzip it, making sure your AV doesn't quarantine anything.
1. Double click on rathammer.exe
1. If you use a non standard steam directory, click the 'edit config' button to locate it.
1. If you need to configure games see the [docs](doc/start.md)

## Installing on Linux
1. [Download](https://github.com/nmalthouse/rathammer/releases)
1. Extract the files
1. Install wine if you want to run the compile tools.
1. Double click rathammer or run it from a terminal with ./rathammer
1. In order to make maps for Valve games, you will need to install them with Proton, see below.

### Getting vbsp.exe, fgd files, etc on Linux
I will use Tf2 as an example.

1. Locate Tf2 in your steam library, right click it and select -> properties -> compatibility -> check and select Proton
1. You may have to install the SourceSdk or the games authoring tools (unsure)
1. Let the game update
1. Navigate to the games folder, by default this is `~/.local/share/Steam/steamapps/Team Fortress 2`
1. Inside that folder, look for a folder named 'bin', it should contain various '.exe' and '.fgd' that only ship with the Windows version
1. copy the `bin` folder to `BIN`, on the terminal: `cp -r bin BIN`
1. Go back to step one and disable Proton if you want to play the game natively. Steam should not touch the BIN folder you made.
1. Launch rathammer

[More info for Linux](doc/start.md#linux)

## Contact
[Discord server](https://discord.gg/wP7gMXpcNR)
I don't go on the Discord much. oops

Email me or open an issue on sourcehut, my email can be found in the help menu or with `rathammer email`

### Building from source, Linux and Windows
* The build process is the same on Linux and Windows, you will need git and zig 
* Download zig 0.17.0 [zig](https://ziglang.org/download/)
* run the commands below for building

```
git clone https://github.com/nmalthouse/rathammer.git 
cd rathammer
git submodule update --init --recursive
zig build -Doptimize=ReleaseFast

./zig-out/bin/rathammer editor
```

### Credits
* zig (best language)
* SDL3
* freetype2
* miniz
* libspng
* stb libs
* zalgebra
* zigglgen
* qoi
* uuid-zig
* Agg2D

Developed by Niklas
