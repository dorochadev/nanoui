# nanoui, forked for Asterisk

nanoui 0.9.2 from https://github.com/justrach/nanoui at `2e863435cc00c92dfc86cfec4f29a32c08daaef0`, as Zig's package
cache had it. Changes from upstream are listed here, so they can go back as pull requests:

- **Glass in a shape** (`types.Glass.shape`). A pane can take the shape of what an SVG document fills, holes and
  all, instead of its rounded box:

  ```zig
  ui.div(c).size(140, 140).glass(.{ .style = .clear, .shape = .{ .key = "asterisk-mark", .svg = mark_svg } }).end();
  ```

  The viewBox is fitted into the box (centered, proportions kept). For each key and size (in pixels, at most 512 a
  side) nanoui draws the shape's signed distance field once (`src/ui/glass_field.zig`: exact distances to the
  flattened outline, the fill rule per shape, the edge's facing from the distance smoothed by a Gaussian) and packs
  it into the image atlas like a picture, so it is cached and evicted as pictures are. The pane's instance points at
  it through `pulse[3]` (1 + x + y * 2048), a field no other glass use touched. Metal (`glass.metal`'s
  `glass_field`) and the CPU renderer (`glass.zig`'s `Field`, `onField`, `shade`) read the same bytes: the edge's
  coverage, how deep a pixel is (the bezel and rim) and the edge's facing (refraction and rim light) come from the
  field, with the bezel no deeper than the shape's deepest point. Rounded panes render exactly as before.
  `svg.zig` gained `outline` (what a document fills, as polygons and fill rules), sharing its walk with `render`.
  Hit testing and layout are still the box's. A shape that can't be read, or whose field isn't drawn yet this frame
  (the image atlas's eight decodes a frame), draws no pane. Drawing a field takes about 90 ms for a 280 px pane in a
  Debug build (8 ms in ReleaseFast), once per size: a pane that animates its size draws one each frame.
  **D3D11 and OpenGL ignore the shape** and draw the pane's rounded box (the div's radius).
  Test: `tests_glass.zig`'s "glass in a shape" (a ring and the asterisk mark over stripes, CPU vs Metal).

- **`ui.hole` lets the pointer through.** It marked its box interactive and never registered it as a stage hole, so
  the frame took every click over it and the native view under it (a web page) got none. It now registers the node
  (`addStageHoleNode`) and isn't a control, so `inStageHoleAt` hands the pointer to the view below.

- **The I-beam holds in a text field.** Moving the pointer inside one box, `mouseMoved` set the cursor from
  `pointerOverText` alone (text that selects), which a text field isn't: the cursor turned to the arrow on every
  move and back to the I-beam on every frame. A field (or text area) under the pointer now sets
  `Context.cursor_field` as it's built, and the I-beam stays anywhere in it.

- **The caret stands before its place.** A text field's bar caret was drawn from the boundary rightwards, over the
  first 1.5 points of the letter after it: in an empty field it sat on the placeholder's first letter. It now ends at
  the boundary (`textfield.zig`, `textfield_lines.zig`); Vim's block still covers the letter it's on.
