**0.5.0-BETA**

- Labels sort themselves out: when a fixture's label would run into a neighbour's label or symbol it moves up a row or to the other side, with a thin tie line back to its fixture. Labels you moved yourself stay put. Switch it off in the left panel or with AUTOLABEL.
- Improvement notes: the yellow Note button (or NOTE, Cmd-Shift-N). Pick Bug, Idea, Change or Question, write it, and mark an area of the drawing to attach a screenshot. NOTES lists them, copies them for Claude or exports them with their pictures.
- DXF: File > Import DXF and Export DXF (DXFIN, DXFOUT). Export is plain R12 in millimetres with fixtures as blocks carrying unit, patch, circuit, position and note as attributes.
- Location tags: tick "Location tag" on a text object and it becomes a tag with that location's tape colours from Lx Book, each colour named. Tags follow colour and name changes made in Lx Book.
- New look to match Lx Book: its dark top bar, hazard yellow, panel and background colours, in light and dark.

**0.4.0-BETA**

- Lx Book link: File > Link to Lx Book (or the Lx Book button in the status bar, or LXBOOK). Fixtures are matched by unit ID; unit ID, universe, address, position and note then stay the same in both apps, whichever you change, within a few seconds. Circuit is read from Lx Book's power patch. Lx Book must be reached over https.
- Right-click menus, as in AutoCAD: one while a command runs (Enter, Cancel, its options, snap overrides), one for selected objects, one for an empty click.
- Groups: G groups the selection, UG ungroups. A click takes the whole group; Option-click takes one member.
- Labels can be moved: LB (or right-click > Move Label), then click where it goes. Optional leader arrow and level text. Also in Object Info.
- Light and dark: View > Appearance, or type DARK, LIGHT or AUTO. Auto follows the Mac.
- Fixed: the drawing no longer paints over the side panels.

**0.3.0-BETA**

- AutoCAD-style workspace: dark model space, crosshair cursor, ribbon, command line and status bar.
- Type commands and aliases: L, PL, C, REC, T, M, CO, RO, E, Z, U, plus TR (truss) and FX (fixture). HELP lists them.
- Type coordinates: x,y  @dx,dy  @dist<angle, or a distance in the direction of the cursor.
- Object snaps: Endpoint, Midpoint, Center, Insertion, Quadrant, Intersection, Perpendicular, Nearest, with markers. F3 osnap, F7 grid, F8 ortho, F9 grid snap.
- Selection the AutoCAD way: clicks add, Shift removes, Command-click toggles; window (left to right) and crossing (right to left) selection.
- Scenes: saved views of layers; one PDF page per scene.
- The app updates itself from GitHub (LX Book Draw menu > Check for Updates).
- New app icon.
