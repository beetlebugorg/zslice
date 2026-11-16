# Problems and errors

## Errors

| Error | Cause | What to do |
|---|---|---|
| `InvalidStl` | The file is not a valid STL file, or it has a coordinate that is not a number. | Export the model again. Check that the file is `.stl` and not `.3mf` or `.obj`. |
| `EmptyMesh` | The file has no triangles, or all triangles are flat (the part has no height). | Check the model in a viewer. |
| `PartTooLarge` | The part is higher than `machine.max_height`. | Turn the part, or scale it in your CAD program. If the printer is taller, set `machine.max_height`. |
| `InvalidSettings` | A setting has a value that cannot make a print. Examples: a layer height of 0, a ratio more than 1, or a layer height larger than the line width. | Check the settings that you changed. |
| `UnknownSetting` | The name after `-s` does not exist. | Run `zslice settings` for the list. Each name has a group: `project.wall_count`, and not `wall_count`. |
| `InvalidValue` | The value has the wrong type. Example: `project.wall_count=two`. | Use a number, `true` or `false`, or one of the listed choices. |

## A part of the model is missing in a layer

The mesh probably has holes or bad triangles. zslice closes gaps in a layer outline that are smaller than `engine.gap_closing` (1 mm). An outline that has a larger gap is removed from that layer.

What to do:

1. Make a preview of the layer: `zslice preview part.stl --layer N -o layerN.svg`.
2. Repair the mesh in your CAD program or in a mesh repair tool, then export it again.
3. As a test, increase the gap: `-s engine.gap_closing=3`.

## A hole in the model is filled

zslice joins all shells of the mesh. If a hole is inside another solid of the same mesh, the solid fills it. This is the expected result for overlapping solids. Example: in the demo part, the tube starts inside the wide box, so the box fills the tube hole below the step.

## The print takes longer than the estimate

The estimate is the distance divided by the speed for each move. The printer must also accelerate and slow down at each corner, so the real time is longer. Short, detailed moves add the most time.
