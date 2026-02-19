# Intro
RatHammer is an editor for Valve's Source engine maps, though it can also be used for standalone mapping.

Open a terminal and navigate to where you downloaded RatHammer.
```
# Run the following command to list possible games and check configuration.
./rathammer --games --checkhealth
```
The output will look like this, if your paths are configured correctly:
```
Loading config file: /home/rat/.config/rathammer/config.vdf
Available game configs:
           tf2
default -> basic_hl2
           gmod
           cstrike
```
To map for a game other than Half Life 2 add one of the listed games with the --game flag
```
./rathammer --game tf2
```

# Games
By Default RatHammer will search for Half Life 2 in your OS's default steam directory
```
On Windows "/Program Files (x86)/Steam/steamapps/common"
On Linux "$HOME/.local/share/Steam/steamapps/common"
```
On Linux the default config file is copied to "$XDG_CONFIG_DIR/rathammer/config.vdf". This defaults to $HOME/.config/rathammer/config.vdf.

On Windows the config is loaded from the XDG_CONFIG_DIR if set, otherwise it just loads the config from cwd.

Games are defined in a folder called 'games' in the config directory

To map for a different Source game or use it for custom levels, you must edit config.vdf and set the default_game appropriately, or launch rathammer with the --game flag.
All paths for game configuration can be temporarily overridden with command line flags, use --help to see these.
If Rathammer fails to start, read through the console output and look for lines like this:
```
Failed to open directory Half-Life 2 in /tmp with error: error.FileNotFound
Set a custom cwd with --custom_cwd flag
```
Unless something horribly wrong happened (Windows builds can be finicky), RatHammer will usually give you good idea of why it can't start.

To load a vmf or ratmap you can use the --map flag, or you can select a map to load once the editor is started.

## Gui
If the scale of the gui is incorrect, set a custom display scale with the --display_scale 1 flag.

This can be permanently set in the config.vdf window section.

## Editing
Once you have successfully started RatHammer you will be greeted by a "pause menu", there are various global settings in here and documentation. Open and close the pause menu with 'Escape'.
RatHammer was designed with 3D editing as the main form. There are 2d views but are relegated to speciality tasks that benefit from a orthographic view, such as alignment and selection of vertices in an axis aligned solid.

Quick reference:

* Navigation -> WASD
* Camera up/down -> space/c
* Change camera speed -> scroll
* Uncapture mouse -> shift
* Pause/console -> Escape
* Grid inc/dec -> R/F
* Duplicate / texture-wrap -> z
* Delete -> ctrl+d
* Pick -> Q
* main 3d view -> alt+1
* texture browser -> alt+t (see workspaces below)
* undo / redo -> ctrl+z, ctrl+shift+z 
* save / save as -> ctrl+s, ctrl+shift+s
* F9 build map (map must have name) -> writes bsp file to "dump.bsp"

Notice how these bindings all sit near wasd, so the left hand doesn't need to move out of position while editing.

All keys can be remapped in the config.vdf file. By default all keys map to physical keys on the keyboard rather than symbols, so if you use a layout other than QWERTY, the keys are in the same place as they would be on a QWERTY layout. This behavior can be changed per key in the config.

## Selections
At any time, you can change the selection. To select an object put the cross-hair (or mouse cursor if you hold shift to uncapture) over an object and press 'E'.
To select more than one object, toggle the selection mode to 'many' using the tab key. 
In the top left corner of the 3d view there is information about the current selection and grid size etc.
To clear the current selection press ctrl+E
By having a separate key for selection, it means the mouse buttons can be used exclusively for object manipulation.

## How RatHammer specifies geometry.
Before you start editing it is important to understand how RatHammer stores brushes and what Source engine games expect of brushes.
Vmf and Bsp files store all brushes as a collection of intersecting planes. This forces any single brush to have certain properties:
* Be fully sealed or 'solid'.
* Be convex, I.E you can shrink wrap it without any air bubbles.
* No two faces can have the same normal.

The last one is important as it means you cannot cut a face in two, to texture it for example, without cutting the entire brush in two.

RatHammer stores and edits polygon meshes, more specifically, each brush is comprised of a set of vertices and 4 or more sides. Each side specifies a convex polygon by indexing into the vertices. RatHammer will not stop you from breaking the above rules, and will often allow you to export broken brushes to vmf, so be careful.

## Tools
At the bottom of the 3d view there is a row of tools, the active tool has a green border around it. Above each icon is the keybinding used to activate that tool.
Some tools may perform an action when you 'activate' that tool again.
On the right of the screen is the inspector. In the 'tools' tab you will find settings and documentation for the current tool.
Most tools require you to "commit" the action. This is done by right clicking. So if you drag a gizmo, you must right click, before letting go of left click, to commit that translation.

### Translate tool
Click and drag the gizmo to translate.
Clicking the white cube above the gizmo will toggle between and translation and rotation gizmo.
Clicking on any part of the selected brushes will let you do a "smart move" If your cursor is > 30 degrees from the horizon, the solid is moved in the xy plane. Otherwise, the solid is moved in the plane of the face you clicked on. 

This smart move function means you can move objects along arbitrary planes, by creating a temporary solid with desired plane, moving along that plane with all selected, then deleting the temporary solid.

The gizmo is always positioned on the centroid of the last selected object. Rotations are done about this point. This means you can specify an arbitrary origin for rotations by creating a temporary object, selecting it last, then doing the rotation.

### Face translate tool.
A Specialized tool for moving the faces of a single solid in an arbitrary direction. If more than one entity is selected it will draw a bounding box around all selected and allow you to scale them proportionally. 

### Place model
Places entities in the world. The default entity is prop_static and if you have a model selected in the model browser (alt+m) that model gets placed. 
To create a brush entity, select entities and press ctrl+t.

### Cube draw
When the cube draw tool is activated, a grid is drawn on z=0. Left click to start, left click again to finish the cube. A red and gray outline of the cube is drawn and you can resize it by left clicking and dragging on a face. Commit the cube with right click. This preview is especially useful for the arch tool as you can resize the bounds and see how the archway will look before committing.

To change the z value of the grid hold q and aim at something in the world. Left click while holding q to set this as the new z.

Pressing z and x move the grid up and down in grid increments.
To change the primitive go to the tool tab in the inspector.

Supported primitives are (cube, arch, cylinder, stairs, dome)

### Fast face
The fast face tool allows to quickly move a solid's faces along their normal.
Selected solids will be outlined in orange. Left click to select the face nearest to you, right click to select the far face.

If more than one solid is selected, faces with common normals are moved together.

The fast face tool is an outlier as it does not require actions to be committed.

### Texture Tool
Select textures with alt+t, switch back to main view with alt+1.

Under the tool tab, the active texture and a list of recent of recent textures is shown. 
Right click on any face to apply the texture. Left click on a face to select it.
Holding z and right clicking will wrap the texture from the selected face. This is equivalent to Hammer's (alt + right click ).

### Vertex tool
In 3d, mouse over a vertex and left click to add. Drag the gizmo and right click to move those vertices.

In the 2d views (alt + 2), left click on a vertex or left click and drag to do a marquee. Hold shift and drag to move all selected vertices.

This vertex tool is temporary and I hope to write a much better one in the future.

### Clipping tool
The clipping tool only works in the 3d viewport for now.
Left click on a selected solid to add the start point, do the same for the second point. The plane you are clipping against will be highlighted in light blue. The red plane is the clipping plane, the blue plane is where the third point lies.
Clicking and dragging the second and third points will allow you to manipulate the clipping plane. Right click to commit the clip. 

The clipping plane will always lie in the normal of the plane you are clipping about (light blue). You can change the selection at any time. The solid you started clipping against does not need to be in the selected when you commit. You can use this to easily specify arbitrary clip planes in 3d.

Currently, clipping solid(s) will remove them from any groups, keep this in mind when clipping collections e.g. staircases.

### Displacements 
There is no displacement tool yet, but very limited editing of displacements can be done.

Create a displacement by selected a face with the texture tool and click "make displacement". Using the vertex tool, the displacement vertices can be moved around. To modify the underlying solid's vertices, check the box under the tool tab.

There is no support yet for: (alpha blend, modifying normals (smoothing), sewing). Displacements can be imported and exported from vmf without loosing information however, so a workaround is exporting to vmf, editing with hammer, then importing that vmf.

### Grid and selection options
Under the tool tab when the translate tool is active, you will find options for grid size and selection mask.
The angle snap can be set here. 

### Visgroups and Layers
Rathammer will import vmf visgroup's as Layers. Each entity can only belong to a single layer. In Hammer this is not the case, so the first visgroup set for a Hammer entity is the visgroup it is put in when importing from vmf.

There are 2 systems for visibility. The AutoVis system, which groups entities based on some predicate. For example (ent.class starts with "prop_") or (solid.texture starts with "tools/skybox").

These filters can be configured at runtime #TODO allow importing of filters

The second system is the Layer system. Navigate to the Layer tab in the inspector.

Clicking on a layer will highlight it blue and make it the 'active layer'. Any new objects you create or duplicate will be placed in the active layer. The checkbox on the left toggles visibility of each layer, the arrow allows collapsing of sub layers.

Right click on any layer for the context menu, the layer does not need to be active. The possible operations include:
* put - move all selected objects to this layer.
* select - add all entities from this layer and its children to the selection.
* duplicate - duplicate this layer and all of its children.
* new child - create a new layer as a child.
* delete - delete this layer and all of its children.
* merge up - merge this layer and all of its children into the previous layer (nearest sibling or parent).

## Workspaces
RatHammer has a few different workspaces.

* alt + 1       main 3d view
* alt + 2       main 2d view
* alt + t       texture browser
* alt + m       model browser


## Using RatHammer as a generic level editor.
See the folder rat_custom in the git repository for a minimal example.

## The console
Press the escape key to toggle the console.

The help command shows a list of commands.

Use the console to: load pointfile, load portalfile, select all entities with a specific class "select_class prop_static"


## Lighting Preview
Rathammer has deferred renderer that can be used to preview light_environment (sunlight), light, and light_spot.

In the pause menu, change the "renderer" to "def". If you don't have a light_environment entity, the world will be bright white! If a map has more than one light_environment, rathammer uses the last one that was set. Change the class of the one you want to use to something else and change it back to light_environment, the values will not be lost, but it will then be the controller of the sunlight.

The renderer is far from perfect currently, and may need manual tuning to make the lighting match Source's.

Under the graphics tab in the pause menu, there are lots of parameters to tune.

If you are on an iGPU and have lots of lights on screen, the framerate may drop. You can increase performance significantly by lowering the resolution of the 3d viewport using the "res scale" slider under graphics. 

## The json map format
For up to date documentation, look at the src/json_map.JsonMap struct.
Every map object (brush, light, prop_static, etc) is given a numeric id. Each of these id's can optionally have some components attached to it. Some of the serialized components include: [solid, entity, displacements, key_values, connections ].
The "objects" key in the json map stores a list of these id's and the attached components for each.
Most data is serialized directly from rathammer, with little transformation, so if you are puzzled about the purpose of a field look at src/ecs.zig to see what it does.
Components:


solid: defines a brush. Has a set of vertices (Vec3) and a set of sides which each contain indexes into the set of vertices.

entity: lights, props, etc.

key_values: Stores a list of arbitrary key value pairs for entities.

connections: Used for source engine style entity input-output. See [valve developer wiki](https://developer.valvesoftware.com/wiki/VMF_(Valve_Map_Format)#Connections)


## The Ratmap format
.ratmap is a container around a json map.

The main reason for this is to compress the json, which usually compresses to 1/20th the size.

A .ratmap is just a [tar](https://en.wikipedia.org/wiki/Tar_(computing)) file containing: 
* map.json.gz -> (required) A [gzipped](https://en.wikipedia.org/wiki/Gzip) json map.
* thumbnail.qoi -> (optional) A [qoi](https://qoiformat.org/) file containing a thumbnail to preview the map.

Maps are always saved to .ratmap but vmf's, json's, ratmaps's can all be loaded by the editor.

Compressing the map.json rather than the entire tar is done because compressing images twice won't significantly improve ratio and quickly loading the thumbnail without decompressing the entire map is a priority.

### Misc 
#### func_useableladder
This entity is really annoying, it is only used by hl2 and portal. 
When you translate a func_useableladder entity, the origin of the entity is synced with the point0 field (the start of the ladder)
The point1 field (end of the ladder) must be set manually. An orange helper outlining the ladders bounds is drawn, but the second part of the hull (point1) can not be manipulated in 3d. Copy and paste a position value into the point1 field.

#### Version checking
Rathammer can be built with version checking enabled.
If enabled, on startup rathammer sends a get request to nmalthouse.net which returns the semver for the newest version available. 

If building from source, it is disabled by default, you must set -Dhttp_version_check=true.

If you would like to disable the check, either set 'enable_version_check false' in config.vdf or use the flag --no_version_check

#### Recent maps view
When you start the editor, a list of recently edited maps is shown.

In the directory where rathammer stores the config (see the first few lines of output when running), a file named recent_maps.txt is created.

This file contains a list of absolute paths to ratmaps separated by newlines

### Troubleshooting / Tips
#### On Linux, after pressing F9 to build nothing seems to happen.
There is some bug with wine, where the first time you run vbsp it will hang indefinitely. Hit f9 again to spin up some new build threads. 

When you try to close the editor, you will have to force kill it as that old vbsp is still hanging. `killall -9 rathammer`

#### On Linux, trying to open or save files does nothing.
Make sure that xdg-desktop-portal is functioning. You can test if it is functioning by installing zenity and running `zenity --file-selection` If the command exits without a window popping up it means your xdg-desktop-portal provider is not configured properly.

#### Error building map
Look through the terminal output. You may have a leak -> press ~ and run the command `pointfile` to trace the leak.

If you see `potentially invalid solid: 12 error.vertsDifferent` -> press ~ and run `select_id 12`. Inspect solid 12 to see if it is broken.

In the future I plan on adding a list view of potential errors.

Problematic solids can often be fixed by selecting them and running the command `optimize`

#### Convert a ratmap to vmf
You can convert a .ratmap or .json to vmf via the command line tool `jsonmaptovmf`.
```
./jsonmaptovmf --map my_map.ratmap --output my_output.vmf
```

#### Some of my custom assets don't show up!
Official Valve tools are case insensitive when it comes to asset names.

Any resource paths specified in vpk's vmf's, vmt's, and mdl's are lowercased and backslashes are converted to forward slashes.

All resource paths in rathammer .json maps are case sensitive.

This means that if you have a vmt file in a loose directory which specifies a vtf "MYVTF.vtf", rathammer will search for 
a file named myvtf.vtf and thus not find it.

In short, if you are having trouble with loose content not getting found, lowercase all of it and remove any '\' characters.

If you have a file named MyCoolTexture.png, rathammer will write MyCoolTexture.png to the map.json and everything will work!

The same is true for gameinfo.txt. Rathammer will only search for the lowercase "gameinfo.txt". Either rename your GaMeInfO.TXT or specify the proper case in config.vdf.

### Credits
```
The zig programming language
https://github.com/ziglang/zig

STB single header c-libs
https://github.com/nothings/stb

SDL3 for window and input
https://wiki.libsdl.org/SDL3/FrontPage

Freetype2
Miniz

Libspng
https://libspng.org/
```
