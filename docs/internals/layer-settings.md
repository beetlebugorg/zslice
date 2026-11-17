# Settings for some layers

An override changes one setting for the layers in a z range (`settings.Override`). Only the settings in `settings.layer_settings` can have an override for a z range. An override of the whole part can change any project or filament setting.

This page lists each project and filament setting. It says if the setting can change per layer, which code reads it, and why a setting cannot change per layer. No machine setting changes per layer: the machine settings describe the printer.

## How the per-layer settings flow

1. `engine.Job.initReuse` puts the overrides of the layer height and the XY offsets aside. Pass 1 reads them (see "The layer height" below).
2. `Job.resolveLayers` makes one `Resolved` for each set of overrides that covers a layer. `Job.resolvedAt(i)` and `layer.Context.resolvedAt(i)` give the settings of layer i. An override covers a layer if the top z of the layer is in its range.
3. `layer.plan` reads all its settings from `resolvedAt(i)`. The plan keeps a pointer to them in `LayerPlan.resolved`.
4. `gcode.Emitter.layer` sets `Emitter.lr` to `LayerPlan.resolved`. The flow, the cooling, the temperatures, the retraction, the z hop, and the combing come from `lr`. The print settings (`Emitter.r`) give the machine, the filament area, and the first layer values.
5. `support.compute` and `islands.find` run once for all layers, with the settings of the print.

## The layer height

`slicer.layerTableSpans` makes the layer table from a list of `slicer.HeightSpan` (a z range and a height). The engine makes one span for each layer height override. A layer starts at the top of the layer below. A span gives its height to the layer if the top of the layer is in its range: the top with the height of the span, or the top with the height that the layer gets without the span. The second test matters for a thinner height: the new top of the selected layer is below the range, but its old top is in it. Where more than one span applies, the last one wins. In a run of layers of one height h that starts at z0, layer k of the run has its top at z0 + k h. So the z values have no sum of rounding errors.

A layer at the start or the end of a span can have another height than the `layer_height` of its own settings, because its settings come from its final top z. So the code reads the height of a layer from `slicer.Layer.height`, and not from `layer_height`:

- The flow: the bead area of a line uses `LayerPlan.height`.
- The speed limit of the max flow uses `LayerPlan.height`.
- The top and bottom skin, the top support band, and the flow infill band count their layers with `layer.layersFor`. Each run of layers of one height gets its part of the thickness. The first layer counts as the layer above it, as before.
- The support overhang distance uses the height of each layer. The support Z gap and the interface are layer counts, so their thickness in mm follows the layer heights.
- The time estimate and the cooling use the moves of each layer.
- The preview gets the z and the height of each layer from `LayerPlan`.
- The engine checks that the height of each layer fits the line width of its layer.

An adaptive layer height (thin layers where a surface has a small slope) can use the same table. It gives its own spans to `layerTableSpans`, before the spans of the overrides, so that an override of the user wins.

"This layer and up" in the app makes a range from the top z of the selected layer. The selected layer gets the new height, for a thinner and for a thicker height. "This layer" with a thinner height gives the z range of the selected layer to thinner layers: two layers of 0.1 mm for one layer of 0.2 mm.

## Combined infill

`project.infill_layers` (n) prints the sparse infill once every n layers. `layer.groups` makes the groups once for the job, and `layer.plan` reads the group of its layer. The decisions:

- **The groups.** The groups count up from the first layer above the bottom skin of the bed (`layersFor` of `bottom_thickness` from layer 0). On a part that stands on the bed, that is the first layer with sparse infill, so the first group is complete. The first layer is never in a group: it has its own line width.
- **The top band.** One count of layers cannot line up with all top surfaces: each top surface of a part is at its own z. So the groups do not try to. The band under a top skin (top support, and the dense band of the flow pattern) is never in the combined area, so it prints on each layer. A group that crosses the start of a band combines only the area that is out of the band in all its layers. The cost is one group of per-layer infill under each top surface, at most.
- **The thickness limit.** A group is not thicker than the nozzle diameter, or the line width if it is smaller (`layer.maxThickness`). The plastic leaves the nozzle as a round thread of the nozzle diameter. In a taller gap, the nozzle does not press the bead down on the bead below. A bead taller than its width is a round thread in the bead model, with no flat side on the layer below. Slic3r and PrusaSlicer have the same limit. A lower limit (for example 0.8 times the nozzle) rules out the main use: two 0.2 mm layers with a 0.4 mm nozzle, and two 0.25 mm layers with a 0.5 mm nozzle. Where n layers are too thick, the group gets fewer layers. The heights are the real heights of the layers (`slicer.Layer.height`), so a group in thin layers can have more layers.
- **Per layer.** `infill_layers` is a per-layer setting. All layers of a group must have the same settings (the same `Resolved`): where an override starts or ends, a new group starts.
- **The area.** `layer.combinedArea` intersects, for all layers of the group, the sparse fill region (after the fill inset) minus the band under a top. A part of the area narrower than half the mean distance of the infill lines (line width / density, at least two line widths) is left out (`narrowLimit`): it holds few lines, and its edge cuts the lines of each layer into short pieces. The last layer of the group fills this area with the pattern, as one bead. Each layer of the group fills the rest of its sparse area as before. The parts of the rest narrower than two line widths get no lines: they are strips along the edge of the combined area, where the walls of a slope move from layer to layer.
- **The pattern.** All patterns work. Gyroid and cubic use the z of the last layer. The patterns that turn by 90 degrees on each layer (lines, zigzag, flow) turn on each group (`InfillGroup.index`), so two groups on top of each other cross.
- **The bead.** The paths have `Path.height`: the sum of the heights of the group. The width is the line width. The emitter computes the flow from the bead model (`flow.beadArea`) for that height, and the speed limit of `filament.max_flow` from the same bead area. The nozzle stays at the z of the last layer. The moves are normal G1 moves with a larger E, and the time estimate uses them as all other moves.
- **The plastic.** A bead of height 2h holds less plastic than two beads of height h of the same width: its round sides are taller (flow.zig). With 0.44 mm lines, one 0.4 mm bead has 11 % less plastic than two 0.2 mm beads. The lines cover the same length times height as before (see the engine tests).
- **The threads.** The plan of a layer needs the sparse areas of the other layers of its group. Another thread can plan those layers at the same time, so a plan cannot read their memos. `Job.combinedAreas` makes the combined area of each group before the plans, on all threads: each group uses the memos of its own layers, so the plans then find their regions in the memos. So the command line tool keeps the regions of all layers until their plans. On the test parts, that is a few percent more peak memory and slice time. To make the regions again in the plans costs about 70 % more slice time. A plan with no combined areas (`Job.planLayer` for one layer) makes the area of its group with new memos for the other layers.

## Filament settings

| Setting | Per layer | Read by | Note |
|---|---|---|---|
| `name`, `color`, `density` | no | gcode, app | For the G-code header, the 3D view, and the statistics. |
| `diameter` | no | settings | The filament area of the whole print. |
| `nozzle_temp` | yes | gcode | M104 at the start of a layer with another value (no wait). |
| `first_layer_nozzle_temp` | no | gcode | The first layer only. The start G-code sets it. |
| `bed_temp` | yes | gcode | M140 at the start of a layer with another value (no wait). The start G-code sets the value of the print. |
| `max_flow` | yes | settings (`Resolved.speed`) | The speed limit of each layer. |
| `flow_ratio` | yes | gcode | The extrusion of each line. |
| `fan_speed`, `fan_max_speed`, `fan_boost_time` | yes | gcode | The fan of each layer. |
| `fan_off_layers` | no | gcode | A count of layers from the bed. Set `fan_speed` to 0 for a range. |
| `min_layer_time`, `min_speed`, `cooling_mode` | yes | gcode | The cooling of each layer. |
| `standby_temp` | no | gcode | Only for the start G-code. |
| `shrinkage_xy`, `shrinkage_z` | no | engine (pass 1) | They scale the whole part. The z scale also sets the part height and the layer table. |
| `xy_offset`, `hole_xy_offset` | yes | engine (pass 1) | Each layer gets the offsets of its z. They are in the outline key. |
| `retract_ratio` | yes | gcode | The retraction of each layer. A push back uses the length of its retraction. |

## Project settings

| Setting | Per layer | Read by | Note |
|---|---|---|---|
| `layer_height` | yes | slicer, engine | See "The layer height". |
| `first_layer_height` | no | slicer | The first layer only. |
| `line_width` | yes | layer, gcode | The support areas and the island search use the line width of the print. |
| `first_layer_line_width` | no | layer | The first layer only. |
| `wall_count`, `wall_thickness`, `thin_walls`, `seam` | yes | layer | |
| `wall_generator`, `min_wall_line_width`, `min_feature_size`, `min_bead_width`, `wall_transition_length`, `wall_transition_angle`, `wall_transition_filter_distance`, `wall_distribution_count` | yes | layer | Arachne makes the walls of each layer from the outline of that layer only. The memo keeps the walls of each layer by their settings (see `Memo.arachneWalls`). |
| `top_thickness`, `bottom_thickness` | yes | layer | Counted with the heights of the layers. |
| `skin_removal_width`, `skin_expand_distance`, `solid_infill_width` | yes | layer | |
| `skin_pattern`, `skin_angle`, `skin_angle_step`, `skin_overlap` | yes | layer | |
| `infill_density`, `infill_pattern`, `infill_angle`, `infill_angles`, `infill_stack`, `infill_flow`, `infill_connect`, `infill_overlap` | yes | layer | |
| `top_support_layers`, `top_support_density` | yes | layer | |
| `lightning_angle` | no | lightning | The branches of all layers come from one pass, from the top down. A layer with another `infill_pattern` cuts the trees: its infill holds the layer above, and the trees start again below it. |
| `infill_layers` | yes | layer | A group of combined infill has the settings of all its layers: a change of the settings starts a new group (see "Combined infill"). |
| `ironing`, `ironing_flow`, `ironing_spacing`, `ironing_inset`, `ironing_speed` | yes | layer, gcode | |
| `outer_wall_speed`, `inner_wall_speed`, `skin_speed`, `infill_speed` | yes | settings (`Resolved.speedAt`) | |
| `slope_smoothing`, `slope_smoothing_min_width`, `slope_smoothing_max_width`, `slope_smoothing_flow`, `slope_smoothing_speed` | yes | layer, settings | The beads of a layer use the settings and the height of that layer. |
| `slope_ironing`, `slope_ironing_passes`, `slope_ironing_flow`, `slope_ironing_speed` | yes | layer, settings | As slope smoothing. |
| `first_layer_speed` | no | settings | The first layer only. |
| `slow_layers` | no | settings | A count of layers from the bed. |
| `outer_wall_accel`, `inner_wall_accel`, `skin_accel`, `infill_accel`, `travel_accel` | yes | settings (`Resolved.accel`), gcode | |
| `first_layer_accel` | no | settings | The first layer only. |
| `retract_min_travel`, `combing`, `combing_max_distance` | yes | gcode | The planning threads find the combing ways with the settings of the layer (`gcode.prepare`). |
| `z_hop` | yes | gcode | The preview draws the lift of a travel with the z hop of the print. |
| `support`, `support_style` | no | support | The support areas of all layers come from one pass. A column or a branch goes through many layers. |
| `support_tree_angle`, `support_tree_spacing`, `support_tree_tip` | no | support | As `support_style`. |
| `support_angle`, `support_xy_gap` | no | support | As `support_style`. |
| `support_z_gap_layers`, `support_interface_layers` | no | support | As `support_style`. |
| `support_density`, `support_interface_density` | yes | layer | The lines in the support areas of each layer. |
| `skirt_loops`, `skirt_distance`, `skirt_layers`, `brim_width` | no | layer, engine | The skirt and the brim are on the first layers, around the first layer. The engine also uses them to place the part. |
| `first_layer_xy_offset` | no | engine | The first layer only. |
| `placement` | no | engine | The place of the whole part. |

## Add a per-layer setting

1. Make each reader of the setting use the settings of the layer: `resolvedAt(i)` in the planner, `Emitter.lr` in the emitter.
2. Add the name to `settings.layer_settings`.
3. Add a test that an override changes only the layers in its range (see the tests in `src/engine.zig`).
4. Update the table on this page.
