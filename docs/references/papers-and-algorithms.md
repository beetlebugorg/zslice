# Papers and algorithms

The papers and the general techniques of geometry and computer science that zslice uses. zslice does not copy code from them. Each zslice file that uses a source names it in its header comment.

## Algorithms, formats, and conventions

### Clipper2 offset method

```ref
kind: idea
source: Clipper2
license: Boost Software License 1.0
link: https://github.com/AngusJohnson/Clipper2
files: src/offset.zig
area: slicing
summary: The offset method.
```

Clipper2, Angus Johnson. https://github.com/AngusJohnson/Clipper2

**License:** Boost Software License 1.0

**Used in:** `src/offset.zig`

**How zslice uses it:** The offset method: move each edge along its normal, join at the vertices (miter, round, or a loop through the original vertex at a closing corner), then a union with the "positive" fill rule. zslice has its own implementation.

### Vatti polygon clipping

```ref
kind: paper
source: Vatti
license: Paper
files: src/clip.zig
area: slicing
summary: Named as the sweep-line method that Clipper uses.
```

Bala R. Vatti, "A generic solution to polygon clipping", Communications of the ACM 35(7), 1992

**License:** Paper

**Used in:** `src/clip.zig`

**How zslice uses it:** Named as the sweep-line method that Clipper uses. zslice uses a different method (planar arrangement and winding numbers).

### Winding numbers and fill rules

```ref
kind: idea
source: General
license: General computational geometry; the names follow the SVG and PostScript fill rules and Clipper2
files: src/clip.zig, src/offset.zig
area: slicing
summary: The rule that decides if a point is inside a polygon set.
```

Winding numbers and fill rules (even-odd, non-zero, positive)

**License:** General computational geometry; the names follow the SVG and PostScript fill rules and Clipper2

**Used in:** `src/clip.zig`, `src/offset.zig`

**How zslice uses it:** The rule that decides if a point is inside a polygon set.

### Shoelace formula

```ref
kind: idea
source: General
license: Mathematics
files: src/geom.zig
area: slicing
summary: The signed area of a polygon.
```

Shoelace formula for polygon area

**License:** Mathematics

**Used in:** `src/geom.zig`

**How zslice uses it:** The signed area of a polygon.

### Fast voxel traversal

```ref
kind: paper
source: Amanatides and Woo
license: Paper
files: src/clip.zig
area: slicing
summary: The walk of an edge through the cells of the uniform grid that finds candidate crossings.
```

John Amanatides and Andrew Woo, "A Fast Voxel Traversal Algorithm for Ray Tracing", Eurographics 1987

**License:** Paper

**Used in:** `src/clip.zig`

**How zslice uses it:** The walk of an edge through the cells of the uniform grid that finds candidate crossings.

### Doubly connected edge list

```ref
kind: idea
source: General
license: Textbook method
files: src/clip.zig
area: slicing
summary: The faces of the arrangement, walked to find the winding numbers.
```

Doubly connected edge list (half-edge structure), as in de Berg et al., "Computational Geometry: Algorithms and Applications"

**License:** Textbook method

**Used in:** `src/clip.zig`

**How zslice uses it:** The faces of the arrangement, walked to find the winding numbers.

### Douglas-Peucker line reduction

```ref
kind: paper
source: Douglas and Peucker
license: Paper
files: src/support_skeleton.zig
area: support
summary: A branch path of one point a layer becomes a chain of nodes: split the path at its worst point until each segment is within the tolerance.
```

David H. Douglas and Thomas K. Peucker, "Algorithms for the reduction of the number of points required to represent a digitized line or its caricature", The Canadian Cartographer 10(2), 1973

**License:** Paper (the method)

**Used in:** `src/support_skeleton.zig`

**How zslice uses it:** A branch path of one point a layer becomes a chain of nodes: split the path at its worst point until each segment is within the tolerance.

### Reciprocal nearest neighbors and union-find

```ref
kind: idea
source: General
license: General techniques
files: src/tree_support.zig
area: support
summary: The plan of the tree joins: rounds of joins of mutual nearest branches, and the groups of regions and of tips, with no dependence on the order of the nodes.
```

Agglomerative clustering by reciprocal nearest neighbors (pairs of points that are each other's nearest point join), and union-find (disjoint sets); general techniques

**License:** General techniques

**Used in:** `src/tree_support.zig`

**How zslice uses it:** The plan of the tree joins: rounds of joins of mutual nearest branches, and the groups of regions and of tips, with no dependence on the order of the nodes.

### Ribbed Support Vaults

```ref
kind: paper
source: Tricard, Claux, and Lefebvre
license: Paper
link: https://diglib.eg.org/handle/10.1111/cgf13750
files: src/lightning.zig
area: infill
summary: The method that the Cura lightning infill comes from.
```

Thibault Tricard, Frédéric Claux, and Sylvain Lefebvre, "Ribbed Support Vaults for 3D Printing of Hollowed Objects", Computer Graphics Forum 39(1), 2020, https://diglib.eg.org/handle/10.1111/cgf13750

**License:** Paper

**Used in:** `src/lightning.zig`

**How zslice uses it:** The method that the Cura lightning infill comes from: walls under the surfaces of a hollow object that get smaller and straighter on the way down, and merge into the walls of the object.

### Clever Support

```ref
kind: paper
source: Vanek, Garcia Galicia, and Benes
license: Paper
files: src/lightning.zig, src/tree_support.zig
area: support
summary: Tree-like support: points under an overhang that join on the way down.
```

Juraj Vanek, Jorge A. Garcia Galicia, and Bedrich Benes, "Clever Support: Efficient Support Structure Generation for Digital Fabrication", Computer Graphics Forum 33(5) (SGP 2014)

**License:** Paper (prior art)

**Used in:** `src/lightning.zig`, `src/tree_support.zig`

**How zslice uses it:** Tree-like support: points under an overhang that join on the way down. Listed as prior art of branch structures.

### Reentrant polygon clipping

```ref
kind: paper
source: Sutherland and Hodgman
license: Paper
files: src/gapfill.zig
area: slicing
summary: The cut of a polygon to a box, one side of the box at a time.
```

Ivan E. Sutherland, Gary W. Hodgman, "Reentrant polygon clipping", Communications of the ACM 17(1), 1974

**License:** Paper

**Used in:** `src/gapfill.zig`

**How zslice uses it:** The cut of a polygon to a box, one side of the box at a time.

### Fortune sweepline Voronoi

```ref
kind: paper
source: Fortune
license: Paper
files: src/voronoi.zig
area: walls
summary: The sweep line method of the Voronoi diagram, which boost::polygon extends to segments.
```

Steven Fortune, "A sweepline algorithm for Voronoi diagrams", Algorithmica 2, 1987

**License:** Paper

**Used in:** `src/voronoi.zig`

**How zslice uses it:** The sweep line method of the Voronoi diagram, which boost::polygon extends to segments. The code is a port of boost::polygon (see "Code in the binaries").

### Arachne: adaptive width control

```ref
kind: paper
source: Kuipers et al.
license: Paper
files: src/arachne/
area: walls
summary: The Arachne method: the skeletal trapezoidation of the medial axis, the beading strategies, and the transitions between bead counts.
```

Tim Kuipers, Eugeni L. Doubrovski, Jun Wu, Charlie C. L. Wang, "A framework for adaptive width control of dense contour-parallel toolpaths in fused deposition modeling", Computer-Aided Design 128, 2020

**License:** Paper

**Used in:** `src/arachne/`

**How zslice uses it:** The Arachne method: the skeletal trapezoidation of the medial axis, the beading strategies, and the transitions between bead counts. The code is a port of CuraEngine (see "Code in the binaries").

### Gyroid

```ref
kind: idea
source: General
license: Mathematics
files: src/infill.zig
area: infill
summary: The gyroid infill pattern.
```

The gyroid, a triply periodic minimal surface (Alan Schoen, 1970), with the common approximation sin x cos y + sin y cos z + sin z cos x = 0. Gyroid infill is in CuraEngine and PrusaSlicer

**License:** Mathematics (the surface); general slicer technique (its use as infill)

**Used in:** `src/infill.zig`

**How zslice uses it:** The gyroid infill pattern. zslice solves the equation for one coordinate in closed form.

### Scanline polygon fill

```ref
kind: idea
source: General
license: General computer graphics technique
files: src/infill.zig
area: infill
summary: The line infill.
```

Scanline polygon fill (sort the edge crossings on each line, fill between them by winding number)

**License:** General computer graphics technique

**Used in:** `src/infill.zig`

**How zslice uses it:** The line infill.

### Greedy nearest-neighbor order

```ref
kind: idea
source: General
license: General technique
files: src/layer.zig
area: slicing
summary: The order of the paths in a layer.
```

Greedy nearest-neighbor path order

**License:** General technique

**Used in:** `src/layer.zig`

**How zslice uses it:** The order of the paths in a layer.

### Morphological opening

```ref
kind: idea
source: General
license: General technique
files: src/offset.zig, src/layer.zig
area: slicing
summary: Removes skin areas that are too thin to print.
```

Mathematical morphology "opening" (erode, then dilate)

**License:** General technique

**Used in:** `src/offset.zig`, `src/layer.zig`

**How zslice uses it:** Removes skin areas that are too thin to print.

### Slab index

```ref
kind: idea
source: General
license: General technique
files: src/clip.zig
area: slicing
summary: Finds the edges that a winding ray crosses.
```

Slab index (bucket edges into equal bands of one axis, then cast a ray only against one band)

**License:** General technique

**Used in:** `src/clip.zig`

**How zslice uses it:** Finds the edges that a winding ray crosses.

### Compressed sparse row layout

```ref
kind: idea
source: General
license: General technique
files: src/clip.zig, src/slicer.zig
area: slicing
summary: The slab index and the per-layer face index.
```

Compressed sparse row (CSR) layout: one array of items and one array of start offsets

**License:** General technique

**Used in:** `src/clip.zig`, `src/slicer.zig`

**How zslice uses it:** The slab index and the per-layer face index.

### Join cut segments by edge ID

```ref
kind: idea
source: General
license: General mesh technique
files: src/slicer.zig
area: slicing
summary: Makes closed loops from the segments of a layer without a coordinate tolerance.
```

Joining cut segments by the ID of the mesh edge that they cross

**License:** General mesh technique

**Used in:** `src/slicer.zig`

**How zslice uses it:** Makes closed loops from the segments of a layer without a coordinate tolerance.

### Polyline simplification

```ref
kind: idea
source: General
license: General technique
files: src/geom.zig
area: slicing
summary: Removes points that change a shape by less than the tolerance.
```

Polyline simplification with an anchor point and a distance bound

**License:** General technique

**Used in:** `src/geom.zig`

**How zslice uses it:** Removes points that change a shape by less than the tolerance.

### Closest point on a triangle

```ref
kind: idea
source: Ericson
license: General computational geometry technique
files: src/plate.zig
area: plate
summary: The side of a part nearest to a picked point, for "this side on the bed".
```

Christer Ericson, "Real-Time Collision Detection" (2005), 5.1.5: the closest point on a triangle

**License:** General computational geometry technique

**Used in:** `src/plate.zig` (`pointTriangle2`)

**How zslice uses it:** The side of a part nearest to a picked point, for "this side on the bed".

### Iterated snap rounding

```ref
kind: idea
source: General
license: General computational geometry technique
files: src/clip.zig
area: slicing
summary: Makes the boolean operations robust after crossing points are rounded to the grid.
```

Iterated snap rounding (repeat the intersection pass on the rounded result)

**License:** General computational geometry technique

**Used in:** `src/clip.zig`

**How zslice uses it:** Makes the boolean operations robust after crossing points are rounded to the grid.

### Snap rounding with hot pixels

```ref
kind: paper
source: Hobby
license: Paper
link: https://doi.org/10.1016/S0925-7721(99
files: src/clip.zig
area: slicing
summary: If the passes of iterated snap rounding do not end, the boolean starts again, and each edge through the unit square around a vertex or a rounded crossing point splits at that point.
```

Snap rounding with hot pixels: J. D. Hobby, "Practical segment intersection with finite precision output", Computational Geometry 13(4), 1999, https://doi.org/10.1016/S0925-7721(99)00021-8

**License:** Paper (method only)

**Used in:** `src/clip.zig`

**How zslice uses it:** If the passes of iterated snap rounding do not end, the boolean starts again, and each edge through the unit square around a vertex or a rounded crossing point splits at that point. The code is new.

### Radix sort

```ref
kind: idea
source: General
license: General technique
files: src/clip.zig
area: slicing
summary: Sorts the cell entries of the crossing grid by cell.
```

Least significant digit radix sort (a stable counting sort for each digit, from the low digit to the high digit)

**License:** General technique

**Used in:** `src/clip.zig`

**How zslice uses it:** Sorts the cell entries of the crossing grid by cell.

### Counting sort

```ref
kind: idea
source: General
license: General technique
files: src/clip.zig
area: slicing
summary: Puts the split points of each edge together (`sortSplits`).
```

Counting sort (count the items of each key, then place each item at the start offset of its key)

**License:** General technique

**Used in:** `src/clip.zig`

**How zslice uses it:** Puts the split points of each edge together (`sortSplits`).

### Structure of arrays box test

```ref
kind: idea
source: General
license: General technique
files: src/clip.zig
area: slicing
summary: The box test of the edge pairs in a grid cell (`testCellsWide`).
```

Structure of arrays with a vector compare: the boxes of many items in one array for each coordinate, tested several at a time, as in the broad phase of collision detection

**License:** General technique

**Used in:** `src/clip.zig`

**How zslice uses it:** The box test of the edge pairs in a grid cell (`testCellsWide`).

### Monotone chain convex hull

```ref
kind: paper
source: Andrew
license: Paper
files: src/offset.zig, src/support_pick.zig
area: support
summary: The convex hull of a loop, for the test that a loop vanishes in an offset; the outline of an overhang under the pointer of the support tool.
```

A. M. Andrew, "Another efficient algorithm for convex hulls in two dimensions", Information Processing Letters 9(5), 1979 (the monotone chain)

**License:** Paper

**Used in:** `src/offset.zig`, `src/support_pick.zig`

**How zslice uses it:** The convex hull of a loop, for the test that a loop vanishes in an offset; the outline of an overhang under the pointer of the support tool.

### Chamfer distance transform

```ref
kind: paper
source: Rosenfeld, Pfaltz, and Borgefors
license: Paper
files: src/bond.zig
area: physics
summary: The distance of each cell of the grid to the first layer, for the area of the brim.
```

Distance transform with chamfer steps (1 and sqrt(2)) in two passes: A. Rosenfeld and J. Pfaltz, "Sequential operations in digital picture processing", Journal of the ACM 13(4), 1966, and G. Borgefors, "Distance transformations in digital images", Computer Vision, Graphics, and Image Processing 34(3), 1986

**License:** Paper (the method)

**Used in:** `src/bond.zig`

**How zslice uses it:** The distance of each cell of the grid to the first layer, for the area of the brim.

### Inscribed circle bound

```ref
kind: idea
source: General
license: Mathematics
files: src/offset.zig
area: slicing
summary: The bound r <= 2 A / P on the largest circle in a convex hull.
```

A convex shape with an inscribed circle of radius r has area A >= r P / 2 (P is the perimeter)

**License:** Mathematics

**Used in:** `src/offset.zig`

**How zslice uses it:** The bound r <= 2 A / P on the largest circle in a convex hull.

### Uniform grid nearest search

```ref
kind: idea
source: General
license: General technique
files: src/layer.zig
area: slicing
summary: Finds the nearest path start in the greedy path order.
```

Uniform grid search for the nearest point, ring by ring

**License:** General technique

**Used in:** `src/layer.zig`

**How zslice uses it:** Finds the nearest path start in the greedy path order.

### Memoization

```ref
kind: idea
source: General
license: General technique
files: src/layer.zig, src/engine.zig
area: slicing
summary: The memo of each layer, which keeps the slow results between slices.
```

Memoization: keep a result with the inputs that made it, and use it again for the same inputs

**License:** General technique

**Used in:** `src/layer.zig`, `src/engine.zig`

**How zslice uses it:** The memo of each layer, which keeps the slow results between slices.

### Arena pools

```ref
kind: idea
source: General
license: General technique
files: src/scratch.zig
area: slicing
summary: The work memory of the booleans and offsets.
```

Arena allocators kept in a pool and reset between uses

**License:** General technique

**Used in:** `src/scratch.zig`

**How zslice uses it:** The work memory of the booleans and offsets.

### Beads between layers (US 5,402,351)

```ref
kind: paper
source: IBM
license: Expired; free to use
files: src/slope.zig
area: slicing
summary: The idea of the slope smoothing pass: after a layer, beads at heights between two layers fill the steps.
```

Extra beads at Z heights between the layers, to fill the stair of a sloped surface: IBM, US 5,402,351 (filed 1991, expired)

**License:** Expired; free to use

**Used in:** `src/slope.zig`

**How zslice uses it:** The idea of the slope smoothing pass: after a layer, beads at heights between two layers fill the steps.

### Anti-aliasing for fused filament deposition

```ref
kind: paper
source: Song et al.
license: Paper
files: src/slope.zig
area: slicing
summary: Small Z changes inside a layer, so that the edge of each layer follows the true surface between the layers.
```

Hai-Chuan Song, Nicolas Ray, Dmitry Sokolov, Sylvain Lefebvre, "Anti-aliasing for fused filament deposition", Computer-Aided Design 89, 2017

**License:** Paper

**Used in:** `src/slope.zig`

**How zslice uses it:** Small Z changes inside a layer, so that the edge of each layer follows the true surface between the layers. zslice uses the idea for its smoothing beads: a Z for each point between two layers.

### Nonplanar layers

```ref
kind: paper
source: Ahlers et al.
license: Paper
files: src/slope.zig
area: slicing
summary: Non-planar moves on top surfaces, and the check of the nozzle shape (a cone) against the printed part.
```

Daniel Ahlers, Florens Wasserfall, Norman Hendrich, Jianwei Zhang, "3D Printing of Nonplanar Layers for Smooth Surface Generation", IEEE CASE 2019

**License:** Paper

**Used in:** `src/slope.zig`

**How zslice uses it:** Non-planar moves on top surfaces, and the check of the nozzle shape (a cone) against the printed part. zslice uses a cone on a flat tip, and checks it against the layer that it just printed, for the smoothing beads and the slope ironing.

### Curved layer FDM paths

```ref
kind: paper
source: Chakraborty et al.
license: Paper
files: src/slope.zig
area: slicing
summary: Extrusion paths with a Z that changes along the path.
```

Debapriya Chakraborty, B. Aneesh Reddy, A. Roy Choudhury, "Extruder path generation for Curved Layer Fused Deposition Modeling", Computer-Aided Design 40(2), 2008

**License:** Paper

**Used in:** `src/slope.zig`

**How zslice uses it:** Extrusion paths with a Z that changes along the path.

### Triangle volume and point to segment distance

```ref
kind: idea
source: General
license: Mathematics
files: src/slope.zig, src/geom.zig
area: slicing
summary: The plastic of a smoothing bead, and the room for the nozzle.
```

Volume of a triangle (h * L / 2) and the distance from a point to a segment

**License:** Mathematics

**Used in:** `src/slope.zig`, `src/geom.zig`

**How zslice uses it:** The plastic of a smoothing bead, and the room for the nozzle.

### Paint brush and pick

```ref
kind: paper
source: Ericson, Moller and Trumbore, Amanatides and Woo
license: Published methods
files: src/paint.zig
area: ui
summary: The brush (which triangles a sphere touches), and the pick of a triangle under the pointer for the paint tool.
```

The closest point of a triangle to a point: Christer Ericson, "Real-Time Collision Detection" (2005), 5.1.5; the ray and triangle test of Möller and Trumbore, "Fast, Minimum Storage Ray/Triangle Intersection" (1997); the cell walk of a ray through a grid of Amanatides and Woo, "A Fast Voxel Traversal Algorithm for Ray Tracing" (1987)

**License:** Published methods

**Used in:** `src/paint.zig`

**How zslice uses it:** The brush (which triangles a sphere touches), and the pick of a triangle under the pointer for the paint tool.

### Marching squares and the regions of many labels

```ref
kind: paper
source: Lorensen and Cline, Wu and Sullivan
license: Published methods
files: src/field.zig, src/paint_split.zig
area: slicing
summary: The borders between the labels of a grid: a point on each grid edge between two labels, a straight piece in a cell with two labels, and pieces to the center of a cell with more labels.
```

William E. Lorensen and Harvey E. Cline, "Marching Cubes: A High Resolution 3D Surface Construction Algorithm", SIGGRAPH 1987 (the patent US 4,710,876 ended in 2005); the 2D form is known as marching squares. For cells with more than two materials: Ziji Wu and John M. Sullivan, "Multiple material marching cubes algorithm", International Journal for Numerical Methods in Engineering 58 (2003), the idea of a point in the middle of a cell that all its materials share

**License:** Published methods

**Used in:** `src/field.zig`, `src/paint_split.zig`

**How zslice uses it:** The regions of the filaments of a painted layer come from the labels of a grid: a border point on each grid edge where the two states are at the same distance, a straight piece in a cell with two labels, and pieces to the center of a cell with three or four labels. The regions of two labels then have no gap between them.

### Distance fields: exact stamps, the chamfer distance, and the jump flood

```ref
kind: paper
source: Borgefors, Rong and Tan, Hoff et al.
license: Published methods
files: src/field.zig
area: slicing
summary: The distance from each node of a grid to the nearest source: each source writes its exact distance to the nodes around it; a two-pass chamfer distance for a coarse test; the jump flood as the GPU form.
```

Gunilla Borgefors, "Distance transformations in digital images", Computer Vision, Graphics, and Image Processing 34 (1986): the two-pass chamfer distance. Kenneth E. Hoff III, Tim Culver, John Keyser, Ming Lin, and Dinesh Manocha, "Fast Computation of Generalized Voronoi Diagrams Using Graphics Hardware", SIGGRAPH 1999: each source draws its distance into a buffer, and the least value wins. Guodong Rong and Tiow-Seng Tan, "Jump Flooding in GPU with Applications to Voronoi Diagram and Distance Transform", I3D 2006: the same field in log n passes on a GPU

**License:** Published methods

**Used in:** `src/field.zig`

**How zslice uses it:** `Field.stampSegment` writes the exact distance of each source to the nodes within a radius, and each node keeps the least value (the method of Hoff et al., on the CPU, a vector of nodes a step). `Field.chamfer` is the two-pass distance of Borgefors, for the test "is paint near this core". The jump flood is the plan for the same field on a GPU; zslice has no code of it.
