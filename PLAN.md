# LX Book Draw - project plan

Native Mac app (Swift + AppKit, no web view) for drawing 2D lighting plots, modelled on Vectorworks
Spotlight. Reference plot: Good Charlotte 4Wall UK V1.1. Companion to Lx Book (show paperwork).
Owner: Stuart. Just for his own use for now. Version scheme as Lx Book: major.minor.patch-BETA.

## How it is built
- Swift Package (no Xcode project). `scripts/build_app.sh` makes a universal "LX Book Draw.app", ad-hoc signed.
- `.github/workflows/build.yml` builds on every push to main and uploads the zipped app.
- STATUS: the code has never been compiled. Claude's workspace has no Swift toolchain. The first GitHub
  build will show compile errors to fix. A private repo still has to be created by Stuart.

## Spotlight ideas carried over
- Design layers; objects carry data; lighting devices hang on truss ("hanging positions") and take its
  position name; a label legend shows unit / universe+address / circuit; a key counts what is used.
- Tool keys match Spotlight: X select, H pan, 1 text, 2 line, 4 rectangle, 5 polyline, 6 ellipse. Cmd-6 fits.

## Files
- Model.swift        Drawing, Layer, DrawObject, FixtureDef, SymPrim (all Codable; file = JSON, .lxdraw, mm, Y up)
- Library.swift      Truss types (approximate widths) and built-in hoist symbols
- GDTF.swift         GDTF Share client (login.php, getList.php, downloadFile.php; same API as Lx Book),
                     Keychain, .gdtf reader, plan symbol built from GDTF model sizes and geometry positions
- GDTFBrowser.swift  Search sheet
- Geometry.swift     Transforms, hit testing, bounds, fixture-to-truss attach
- Renderer.swift     Draws everything into a CGContext (screen and PDF)
- CanvasView.swift   Zoom, pan, snapping, tools, copy/paste
- MainWindowController.swift  Tool palette, resources, layers, Object Info
- PDFExport.swift    A3 sheet with key and title block
- Document.swift, main.swift, Controls.swift

## Stages
1. DONE (uncompiled): canvas, layers, shapes, save/open, undo
2. DONE (uncompiled): truss runs, fixtures from GDTF, labels, key, basic PDF sheet
3. Sheets: sheet layers, viewports, proper title block editor, scales, classes
4. DXF import/export (own reader/writer; symbols <-> blocks, data <-> attributes)
5. DWG (LibreDWG for reading; writing only to older DWG versions; GPL fine while app is private)
6. Lx Book link (.lxshow in/out), MVR export with the GDTF files

## Added in 0.2.0
- Scenes (saved views): named sets of visible layers, in the left panel; one PDF page per scene.
- Command-click (as well as Shift-click) adds to or removes from the selection.
- STATUS: 0.1.0 compiled first time on GitHub (public repo picton83/lx-book-draw, Intel runner).

## Known gaps to pick up
- Fixture labels always sit on the fixture's local "up" side; no flip or per-fixture label offset yet.
- GDTF top-view SVGs (models/svg/*.svg) are not read yet; symbols come from model boxes instead.
- Truss widths are approximate; no truss/symbol editor yet.
- Rotating a truss in Object Info does not swing its fixtures round with it.
- No dimensions tool, no arcs, no groups, no classes, no line styles, no resize handles.
- Layer lock exists in the file but has no button.
