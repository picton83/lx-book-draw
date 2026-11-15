**0.13.1-BETA**

- Freeze is now Lock, as in AutoCAD: a locked layer stays showing (faded on screen, normal in the PDF), but nothing on it can be selected, moved or changed. You can still snap to it. A layer frozen in 0.13.0 shows again.

**0.13.0-BETA**

- Layers are a drop-down, as in AutoCAD: click the current layer in the left menu for every layer, with Show, Freeze, a colour, and whether things on it use the layer's colour or keep their own (a fixture keeps its symbol colour). Click a layer's name to make it current.
- Freeze: a frozen layer is hidden and left out of selecting, snapping and the PDF, whatever a scene or viewport says. The current layer can't be frozen.
- Scenes are a drop-down: pick a scene to show it; save, update, rename and delete are in the same list.
- The top bar's groups (Draw, Lighting, Modify, Tools, View) are drop-down menus, with Undo and Redo beside them.
- Measure: DI (or MEA, or Tools > Measure Distance). Click two points; the length shows as you move and the answer is in millimetres, metres and feet and inches, with the angle and how far across and up.
- Follow spots: a fixture Lx Book marks as a follow spot gets Lx Book's blue FS circle beside it.
- A linked fixture's ID can't be left blank; it goes back to Lx Book's.
- Notes finished in earlier versions now clear from the notes list even if that version was skipped.

**0.12.2-BETA**

- The window can be made smaller again: the left menu and Object Info scroll when there is more in them than fits, so a long list of layers no longer makes the window taller than the screen.
- One Open Recent menu, not two. It now also lists the drawings and the last show you had open before this update, and the reopen question at launch can offer them.

**0.12.1-BETA**

The Lx Book layout, from your screenshots:

- A dark menu down the left, full height: the Lx Book Draw name plate, the show's name and how it stands with Lx Book, then Truss, Fixtures, Snapping, Scenes and Layers under hazard-yellow section titles.
- A light bar across the top with flat white buttons, grouped, and the Note button in soft yellow.
- Object Info and the other panels keep the white buttons and bold headings with a rule.

**0.12.0-BETA**

From your improvement notes of 15 November.

- The fixture ID is the link to Lx Book and is never changed there from Draw. Typing a new ID on a fixture makes it Lx Book's fixture with that ID, with its patch, position, notes and power. If Lx Book has no free fixture with that ID, the plot fixture keeps the ID you typed and is no longer linked.
- File > Open Recent lists your last 12 drawings and shows, and the list now survives updates.
- At launch the app asks whether to open the last drawing again.
- Labels sit closer to their fixtures when their lines are made smaller in Fixture Label Config, and the dialog can put labels you moved by hand back next to their fixtures.
- More of the Lx Book look: flat white buttons with thin edges, bold section headings with a rule, grey side panels.

**0.11.0-BETA**

Works with Lx Book 1.0.76.

- Sign in to Lx Book with your username and password (File > Sign In to Lx Book, and on first launch). The password isn't kept; the Mac gets a key of its own, kept in the Keychain. File > Sign Out of Lx Book deletes it.
- Open Show from Lx Book lists the shows shared with you and opens the one you pick, whatever show your browser has open.
- An empty show offers to start a new drawing or bring in a drawing file.
- Moving a drawing file into a show that already has one now asks: open the drawing in Lx Book, replace it with this file (Undo in Lx Book brings the old one back), or cancel.
- Cmd-S on a show sends anything waiting. File > Export Drawing File saves a copy on disk.
- Link to Lx Book on a drawing file now picks the show from your list too.

**0.10.0-BETA**

The drawing can now live inside the show in Lx Book. This needs Lx Book's matching update (its health check must say draw 2); until then the app says so and keeps your changes on this Mac.

- File > Open Show from Lx Book opens the drawing kept in the show you have open in Lx Book. There is no file to look after: every change is saved to the show about a second after you make it, and changes made by someone else arrive within a few seconds.
- With no signal you carry on working. Changes wait on this Mac and are sent when Lx Book is reachable again, and Lx Book merges them item by item.
- File > Move This Drawing into the Lx Book Show takes a linked drawing file and makes the show its home. It is only sent if the show has no drawing yet.
- Fixture symbols are saved to Lx Book's symbol library and fetched from it, so the show itself stays small.
- Drawing files still work exactly as before.

**0.9.2-BETA**

- Every PDF page has a notice across the top: the plot is auto-generated, its fixture numbers, addresses and power are correct from Lx Book, and the placement of truss and fixtures is indicative only and not for rigging.
- Viewer QR code: paste the link behind Lx Book's view-only QR code into Viewer link (Object Info on the Model tab with nothing selected) and it is printed on every PDF page.
- On a sheet made before this version, use Fill the Sheet on a viewport if the notice covers its top edge.

**0.9.1-BETA**

- Viewport layouts for a sheet: One, Two Side by Side, Two Top and Bottom, and Four. They are in Object Info when a sheet is showing with nothing selected. Each viewport takes the next scene in turn.
- A viewport now has its own Scene setting in Object Info, and keeps its own layers. What the Model tab is showing no longer changes what a sheet shows.

**0.9.0-BETA**

- Sheets, as AutoCAD's paper space: tabs under the command line, Model first, then one tab per sheet. Each sheet is a page of the PDF that Lx Book shows. The + tab adds a sheet, or one for every scene.
- Viewports: a sheet shows the drawing through viewports. MV makes one with two clicks. Drag it to move it, drag its corners to resize it, double-click inside to slide the view and scroll to change its scale. Object Info sets the scale (1:50, 1:100 and so on), locks it, and picks which layers show in that viewport.
- On a sheet: paper size and direction, key and title block on or off, and text written straight on the paper (T).
- A drawing with no sheets makes its PDF as before, one page per scene.
- Symbol colour: select a fixture and pick a colour in Object Info; every fixture of that type takes it.
- Easy ID: a letter or two in a box on the symbol (such as K), set in Object Info for the fixture type.

**0.8.0-BETA**

- Once a drawing is linked to Lx Book, it is saved into that show's own folder in Lx Book's file storage (Dropbox), by itself, a few seconds after each change: the drawing file and a PDF of it. The status bar says when it was last saved there.
- This needs Lx Book's matching update. Until Lx Book has it, the app says so once and carries on as before.

**0.7.0-BETA**

- Real fixture symbols from GDTF: a fixture added from GDTF Share or a .gdtf file now uses the manufacturer's own plan drawing from inside the file, at its real size.
- When a GDTF file has no plan drawing, the outline of each part is taken from its 3D model instead of a plain box.
- Fixtures already in a drawing keep their old symbol until that type is added again from GDTF.

**0.6.0-BETA**

From your improvement notes of 14 November.

- Moving, copying, rotating and scaling now float: what you picked follows the cursor until you click.
- SCALE (SC): pick a base point, then type a factor or click. Drawn shapes and text change size; truss and fixtures keep their real size. Scenes are now SN or SCENE.
- Grips, as in AutoCAD: select something and drag its blue squares to stretch a line or resize a shape, the middle square to move it, the green dot to rotate it (Shift for 15 degree steps).
- Fixture Label Config (Labels button, LC, or Modify menu): tick what the label shows (fixture ID, address, plug up, position, type, note), set each line's size, and change the order.
- Label text has a white background so it reads over truss. It can be switched off in Fixture Label Config.
- Undo, Redo and Log buttons in the top bar. The change log (LOG, or Edit > Change Log) lists every change with its time and is saved in the drawing.
- Drawings open as tabs in one window.
- Constant saving: once a drawing has a file, every change is saved two seconds after you make it. File > Save to Dropbox puts the file in Dropbox / LX Book Draw.
- File > Keep a PDF Up to Date in a Folder (PUBLISH): choose the show's folder in Dropbox / Lx Book and the plot shows in Lx Book's Plots & files, refreshed as you draw. UNPUBLISH stops it.
- Truss is drawn with tube chords, bracing and end frames when you zoom in.
- More of the Lx Book look: name plate, section headings, yellow on/off pills in the status bar, lined panels.

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
