# Cura and OrcaSlicer settings

Each setting of Cura and of OrcaSlicer, and the zslice setting that does the same. Use this page to move a profile from another slicer to zslice. `zslice import cura` converts the settings of a Cura profile with a zslice setting.

<!-- tools/setting_coverage.py makes this page. Do not edit it by hand. -->

The status of a setting:

- **Same**: zslice has a setting with the same meaning. The column names it.
- **Covered**: zslice does the same with no setting of its own, or another setting covers it.
- **Missing**: zslice does not have it yet.
- **Not for zslice**: a setting for other hardware, for the app of the other slicer, or for a method that zslice does in another way.

The lists come from Cura `resources/definitions/fdmprinter.def.json` and `fdmextruder.def.json` (commit `1a221ec29a86`) and OrcaSlicer `src/libslic3r/PrintConfig.cpp` (commit `97e2d0a6e687`).

## Totals

| Slicer | Settings | Same | Covered | Missing | Not for zslice |
|---|---|---|---|---|---|
| Cura | 762 | 169 | 91 | 439 | 63 |
| OrcaSlicer | 1013 | 161 | 122 | 498 | 232 |

## Cura

### Quality

| Cura setting | Status | zslice |
|---|---|---|
| `layer_height` (Layer Height) | Same | `project.layer_height` |
| `layer_height_0` (Initial Layer Height) | Same | `project.first_layer_height` |
| `line_width` (Line Width) | Same | `project.line_width` |
| `wall_line_width` (Wall Line Width) | Missing | a line width of the walls |
| `wall_line_width_0` (Outer Wall Line Width) | Missing | a line width of the outer wall |
| `wall_line_width_x` (Inner Wall(s) Line Width) | Missing | a line width of the inner walls |
| `skin_line_width` (Top/Bottom Line Width) | Missing | a line width of the skin |
| `infill_line_width` (Infill Line Width) | Missing | a line width of the infill |
| `skirt_brim_line_width` (Skirt/Brim Line Width) | Covered | the skirt and the brim use `project.first_layer_line_width` |
| `support_line_width` (Support Line Width) | Missing | a line width of the support |
| `support_interface_line_width` (Support Interface Line Width) | Missing | a line width of the support interface |
| `support_roof_line_width` (Support Roof Line Width) | Missing | a line width of the support roof |
| `support_bottom_line_width` (Support Floor Line Width) | Missing | a line width of the support floor |
| `prime_tower_line_width` (Prime Tower Line Width) | Missing | a line width of the prime tower |
| `initial_layer_line_width_factor` (Initial Layer Line Width) | Same | `project.first_layer_line_width` (a width in mm) |

### Walls

| Cura setting | Status | zslice |
|---|---|---|
| `wall_extruder_nr` (Wall Extruder) | Covered | painted filaments, and `project.filament` for a part |
| `wall_0_extruder_nr` (Outer Wall Extruder) | Missing | another filament for the outer wall |
| `wall_x_extruder_nr` (Inner Wall Extruder) | Missing | another filament for the inner walls |
| `wall_thickness` (Wall Thickness) | Same | `project.wall_thickness` |
| `wall_line_count` (Wall Line Count) | Same | `project.wall_count` |
| `wall_transition_length` (Wall Transition Length) | Same | `project.wall_transition_length` |
| `wall_distribution_count` (Wall Distribution Count) | Same | `project.wall_distribution_count` |
| `wall_transition_angle` (Wall Transitioning Threshold Angle) | Same | `project.wall_transition_angle` |
| `wall_transition_filter_distance` (Wall Transitioning Filter Distance) | Same | `project.wall_transition_filter_distance` |
| `wall_transition_filter_deviation` (Wall Transitioning Filter Margin) | Covered | zslice uses the Cura default (a quarter of the nozzle) |
| `wall_0_wipe_dist` (Outer Wall Wipe Distance) | Same | `project.outer_wall_wipe` |
| `wall_0_inset` (Outer Wall Inset) | Missing | move the outer wall in |
| `wall_x_inset` (Inner Wall Inset) | Missing | move the inner walls in |
| `optimize_wall_printing_order` (Optimize Wall Printing Order) | Covered | zslice prints the walls of an island in the nearest order |
| `inset_direction` (Wall Ordering) | Same | `project.wall_order` |
| `initial_layer_inset_direction` (Initial Layer Wall Ordering) | Missing | the wall order of the first layer |
| `alternate_extra_perimeter` (Alternate Extra Wall) | Same | `project.alternate_extra_wall` |
| `min_wall_line_width` (Minimum Wall Line Width) | Same | `project.min_wall_line_width` |
| `min_even_wall_line_width` (Minimum Even Wall Line Width) | Covered | `project.min_wall_line_width` |
| `min_odd_wall_line_width` (Minimum Odd Wall Line Width) | Covered | `project.min_wall_line_width` |
| `fill_outline_gaps` (Print Thin Walls) | Same | `project.thin_walls` |
| `min_feature_size` (Minimum Feature Size) | Same | `project.min_feature_size` |
| `min_bead_width` (Minimum Thin Wall Line Width) | Same | `project.min_bead_width` |
| `xy_offset` (Horizontal Expansion) | Same | `filament.xy_offset` |
| `xy_offset_layer_0` (Initial Layer Horizontal Expansion) | Same | `project.first_layer_xy_offset` |
| `hole_xy_offset` (Hole Horizontal Expansion) | Same | `filament.hole_xy_offset` |
| `hole_xy_offset_max_diameter` (Hole Horizontal Expansion Max Diameter) | Missing | the hole offset only for holes up to a size |
| `z_seam_type` (Z Seam Alignment) | Same | `project.seam` |
| `z_seam_on_vertex` (Z Seam On Vertex) | Covered | the zslice seams are on a vertex |
| `z_seam_position` (Z Seam Position) | Missing | a seam at a side of the bed (back left, front, and others) |
| `z_seam_x` (Z Seam X) | Missing | a seam near a point |
| `z_seam_y` (Z Seam Y) | Missing | a seam near a point |
| `z_seam_corner` (Seam Corner Preference) | Same | `project.seam_corner` |
| `z_seam_relative` (Z Seam Relative) | Missing | a seam point relative to the part |

### Top and bottom

| Cura setting | Status | zslice |
|---|---|---|
| `roofing_extruder_nr` (Top Surface Skin Extruder) | Missing | another filament for the top surface |
| `roofing_layer_count` (Top Surface Skin Layers) | Missing | top surface skin layers with their own settings |
| `roofing_line_width` (Top Surface Skin Line Width) | Missing | the line width of the top surface skin |
| `roofing_pattern` (Top Surface Skin Pattern) | Missing | the pattern of the top surface skin |
| `roofing_monotonic` (Monotonic Top Surface Order) | Missing | monotonic order on the top surface skin |
| `roofing_angles` (Top Surface Skin Line Directions) | Missing | the angles of the top surface skin |
| `roofing_expansion` (Top Surface Expansion) | Missing | the width of the top surface skin |
| `flooring_extruder_nr` (Bottom Surface Skin Extruder) | Missing | another filament for the bottom surface |
| `flooring_layer_count` (Bottom Surface Skin Layers) | Missing | bottom surface skin layers with their own settings |
| `flooring_line_width` (Bottom Surface Skin Line Width) | Missing | the line width of the bottom surface skin |
| `flooring_pattern` (Bottom Surface Skin Pattern) | Missing | the pattern of the bottom surface skin |
| `flooring_monotonic` (Monotonic Bottom Surface Order) | Missing | monotonic order on the bottom surface skin |
| `flooring_angles` (Bottom Surface Skin Line Directions) | Missing | the angles of the bottom surface skin |
| `top_bottom_extruder_nr` (Top/Bottom Extruder) | Missing | another filament for the skin |
| `top_bottom_thickness` (Top/Bottom Thickness) | Same | `project.top_thickness` and `project.bottom_thickness` |
| `top_thickness` (Top Thickness) | Same | `project.top_thickness` |
| `top_layers` (Top Layers) | Same | `project.top_thickness` (the importer multiplies by the layer height) |
| `bottom_thickness` (Bottom Thickness) | Same | `project.bottom_thickness` |
| `bottom_layers` (Bottom Layers) | Same | `project.bottom_thickness` (the importer multiplies by the layer height) |
| `initial_bottom_layers` (Initial Bottom Layers) | Missing | a bottom layer count on the bed |
| `top_bottom_pattern` (Top/Bottom Pattern) | Same | `project.skin_pattern` |
| `top_bottom_pattern_0` (Bottom Pattern Initial Layer) | Missing | the skin pattern of the first layer |
| `top_bottom_skin_merge_distance` (Top/Bottom/Skin Merge Distance) | Missing | join skin areas that are near each other |
| `connect_skin_polygons` (Connect Top/Bottom Polygons) | Missing | join the skin lines of a concentric skin |
| `skin_monotonic` (Monotonic Top/Bottom Order) | Same | `project.skin_pattern = monotonic` |
| `skin_angles` (Top/Bottom Line Directions) | Same | `project.skin_angle` and `project.skin_angle_step` |
| `small_skin_width` (Small Top/Bottom Width) | Missing | small skin areas print as walls |
| `small_skin_on_surface` (Small Top/Bottom On Surface) | Missing | small skin areas on the surface print as walls |
| `skin_no_small_gaps_heuristic` (No Skin in Z Gaps) | Covered | `project.gap_fill` |
| `skin_outline_count` (Extra Skin Wall Count) | Missing | walls around the skin |
| `ironing_enabled` (Enable Ironing) | Same | `project.ironing` |
| `ironing_only_highest_layer` (Iron Only Highest Layer) | Missing | iron the top layer of the part only |
| `ironing_pattern` (Ironing Pattern) | Missing | the pattern of the ironing |
| `ironing_monotonic` (Monotonic Ironing Order) | Missing | monotonic order of the ironing |
| `ironing_line_spacing` (Ironing Line Spacing) | Same | `project.ironing_spacing` |
| `ironing_flow` (Ironing Flow) | Same | `project.ironing_flow` |
| `ironing_inset` (Ironing Inset) | Same | `project.ironing_inset` |
| `speed_ironing` (Ironing Speed) | Same | `project.ironing_speed` |
| `acceleration_ironing` (Ironing Acceleration) | Missing | the acceleration of the ironing |
| `jerk_ironing` (Ironing Jerk) | Missing | the jerk of the ironing |
| `skin_overlap` (Skin Overlap Percentage) | Same | `project.skin_overlap` |
| `skin_overlap_mm` (Skin Overlap) | Same | `project.skin_overlap` (a ratio of the line width) |
| `skin_preshrink` (Skin Removal Width) | Same | `project.skin_removal_width` |
| `top_skin_preshrink` (Top Skin Removal Width) | Covered | `project.skin_removal_width` |
| `bottom_skin_preshrink` (Bottom Skin Removal Width) | Covered | `project.skin_removal_width` |
| `expand_skins_expand_distance` (Skin Expand Distance) | Same | `project.skin_expand_distance` |
| `top_skin_expand_distance` (Top Skin Expand Distance) | Covered | `project.skin_expand_distance` |
| `bottom_skin_expand_distance` (Bottom Skin Expand Distance) | Covered | `project.skin_expand_distance` |
| `max_skin_angle_for_expansion` (Maximum Skin Angle for Expansion) | Missing | expand only the skin of flat surfaces |
| `min_skin_width_for_expansion` (Minimum Skin Width for Expansion) | Missing | expand only wide skin areas |

### Infill

| Cura setting | Status | zslice |
|---|---|---|
| `infill_extruder_nr` (Infill Extruder) | Missing | another filament for the infill |
| `infill_sparse_density` (Infill Density) | Same | `project.infill_density` |
| `infill_line_distance` (Infill Line Distance) | Same | `project.infill_density` (the importer computes the density) |
| `infill_pattern` (Infill Pattern) | Same | `project.infill_pattern` |
| `zig_zaggify_infill` (Connect Infill Lines) | Same | `project.infill_connect` |
| `connect_infill_polygons` (Connect Infill Polygons) | Missing | join the loops of concentric infill |
| `infill_angles` (Infill Line Directions) | Same | `project.infill_angles` |
| `infill_offset_x` (Infill X Offset) | Missing | move the infill grid |
| `infill_offset_y` (Infill Y Offset) | Missing | move the infill grid |
| `infill_multiplier` (Infill Line Multiplier) | Missing | more infill lines next to each other |
| `infill_wall_line_count` (Extra Infill Wall Count) | Missing | walls around the infill |
| `sub_div_rad_add` (Cubic Subdivision Shell) | Missing | the cubic subdivision infill |
| `infill_overlap` (Infill Overlap Percentage) | Same | `project.infill_overlap` |
| `infill_overlap_mm` (Infill Overlap) | Same | `project.infill_overlap` (a ratio) |
| `infill_wipe_dist` (Infill Wipe Distance) | Missing | a travel after each infill line |
| `infill_sparse_thickness` (Infill Layer Thickness) | Same | `project.infill_layers` |
| `gradual_infill_steps` (Gradual Infill Steps) | Missing | denser infill under the top |
| `gradual_infill_step_height` (Gradual Infill Step Height) | Missing | denser infill under the top |
| `infill_before_walls` (Infill Before Walls) | Missing | print the infill before the walls (zslice prints the walls first: the Cura value False) |
| `min_infill_area` (Minimum Infill Area) | Missing | no infill in small areas |
| `infill_support_enabled` (Infill Support) | Missing | infill only where a top needs it |
| `infill_support_angle` (Infill Overhang Angle) | Missing | infill only where a top needs it |
| `skin_support` (Infill Skin Support) | Missing | lines under the skin |
| `skin_support_speed` (Skin Support Speed) | Missing | lines under the skin |
| `skin_support_material_flow` (Skin Support Flow) | Missing | lines under the skin |
| `skin_support_density` (Skin Support Density) | Missing | lines under the skin |
| `skin_support_fan_speed` (Skin Support Fan Speed) | Missing | lines under the skin |
| `skin_support_interlace_lines` (Interlace Skin Support Lines) | Missing | lines under the skin |
| `lightning_infill_support_angle` (Lightning Infill Support Angle) | Same | `project.lightning_angle` |
| `lightning_infill_overhang_angle` (Lightning Infill Overhang Angle) | Covered | `project.lightning_angle` |
| `lightning_infill_prune_angle` (Lightning Infill Prune Angle) | Covered | `project.lightning_angle` |
| `lightning_infill_straightening_angle` (Lightning Infill Straightening Angle) | Covered | `project.lightning_angle` |
| `infill_move_inwards_length` (Infill Start/End Move Inwards Length) | Missing | a short move into the infill at the end of a line |
| `infill_start_move_inwards_length` (Infill Start Move Inwards Length) | Missing | a short move into the infill at the start of a line |
| `infill_end_move_inwards_length` (Infill End Move Inwards Length) | Missing | a short move into the infill at the end of a line |
| `infill_start_end_preference` (Infill Start/End Preference) | Missing | where the infill lines start and end |

### Material

| Cura setting | Status | zslice |
|---|---|---|
| `default_material_print_temperature` (Default Printing Temperature) | Covered | `filament.nozzle_temp` |
| `build_volume_temperature` (Build Volume Temperature) | Same | `machine.chamber_temp` |
| `material_print_temperature` (Printing Temperature) | Same | `filament.nozzle_temp` |
| `material_print_temperature_layer_0` (Printing Temperature Initial Layer) | Same | `filament.first_layer_nozzle_temp` |
| `material_initial_print_temperature` (Initial Printing Temperature) | Missing | the temperature of a tool that starts after a wait |
| `material_final_print_temperature` (Final Printing Temperature) | Missing | the temperature of a tool before it waits |
| `material_extrusion_cool_down_speed` (Extrusion Cool Down Speed Modifier) | Missing | the cool down of a nozzle while it prints |
| `default_material_bed_temperature` (Default Build Plate Temperature) | Covered | `filament.bed_temp` |
| `material_bed_temperature` (Build Plate Temperature) | Same | `filament.bed_temp` |
| `material_bed_temperature_layer_0` (Build Plate Temperature Initial Layer) | Same | `filament.first_layer_bed_temp` |
| `material_adhesion_tendency` (Adhesion Tendency) | Not for zslice | a material fact of the Cura Marketplace |
| `material_surface_energy` (Surface Energy) | Not for zslice | a material fact of the Cura Marketplace |
| `material_shrinkage_percentage` (Scaling Factor Shrinkage Compensation) | Same | `filament.shrinkage_xy` and `filament.shrinkage_z` |
| `material_shrinkage_percentage_xy` (Horizontal Scaling Factor Shrinkage Compensation) | Same | `filament.shrinkage_xy` |
| `material_shrinkage_percentage_z` (Vertical Scaling Factor Shrinkage Compensation) | Same | `filament.shrinkage_z` |
| `material_crystallinity` (Crystalline Material) | Not for zslice | a material fact of Ultimaker printers |
| `material_anti_ooze_retracted_position` (Anti-ooze Retracted Position) | Not for zslice | the material station of Ultimaker printers |
| `material_anti_ooze_retraction_speed` (Anti-ooze Retraction Speed) | Not for zslice | the material station of Ultimaker printers |
| `material_break_preparation_retracted_position` (Break Preparation Retracted Position) | Not for zslice | the material station of Ultimaker printers |
| `material_break_preparation_speed` (Break Preparation Retraction Speed) | Not for zslice | the material station of Ultimaker printers |
| `material_break_preparation_temperature` (Break Preparation Temperature) | Not for zslice | the material station of Ultimaker printers |
| `material_break_retracted_position` (Break Retracted Position) | Not for zslice | the material station of Ultimaker printers |
| `material_break_speed` (Break Retraction Speed) | Not for zslice | the material station of Ultimaker printers |
| `material_break_temperature` (Break Temperature) | Not for zslice | the material station of Ultimaker printers |
| `material_flush_purge_speed` (Flush Purge Speed) | Not for zslice | the material station of Ultimaker printers |
| `material_flush_purge_length` (Flush Purge Length) | Covered | `machine.flush_volume` |
| `material_end_of_filament_purge_speed` (End of Filament Purge Speed) | Not for zslice | the material station of Ultimaker printers |
| `material_end_of_filament_purge_length` (End of Filament Purge Length) | Not for zslice | the material station of Ultimaker printers |
| `material_maximum_park_duration` (Maximum Park Duration) | Not for zslice | the material station of Ultimaker printers |
| `material_no_load_move_factor` (No Load Move Factor) | Not for zslice | the material station of Ultimaker printers |
| `material_flow` (Flow) | Same | `filament.flow_ratio` |
| `wall_material_flow` (Wall Flow) | Missing | a flow of the walls |
| `wall_0_material_flow` (Outer Wall Flow) | Missing | a flow of the outer wall |
| `wall_x_material_flow` (Inner Wall(s) Flow) | Missing | a flow of the inner walls |
| `wall_0_material_flow_roofing` (Top Surface Outer Wall Flow) | Missing | a flow of the outer wall of the top surface |
| `wall_x_material_flow_roofing` (Top Surface Inner Wall(s) Flow) | Missing | a flow of the inner walls of the top surface |
| `wall_0_material_flow_flooring` (Bottom Surface Outer Wall Flow) | Missing | a flow of the outer wall of the bottom surface |
| `wall_x_material_flow_flooring` (Bottom Surface Inner Wall(s) Flow) | Missing | a flow of the inner walls of the bottom surface |
| `skin_material_flow` (Top/Bottom Flow) | Missing | a flow of the skin |
| `roofing_material_flow` (Top Surface Skin Flow) | Missing | a flow of the top surface skin |
| `flooring_material_flow` (Bottom Surface Skin Flow) | Missing | a flow of the bottom surface skin |
| `infill_material_flow` (Infill Flow) | Same | `project.infill_flow` |
| `skirt_brim_material_flow` (Skirt/Brim Flow) | Missing | a flow of the skirt and the brim |
| `support_material_flow` (Support Flow) | Missing | a flow of the support |
| `support_interface_material_flow` (Support Interface Flow) | Missing | a flow of the support interface |
| `support_roof_material_flow` (Support Roof Flow) | Missing | a flow of the support roof |
| `support_bottom_material_flow` (Support Floor Flow) | Missing | a flow of the support floor |
| `prime_tower_flow` (Prime Tower Flow) | Missing | a flow of the prime tower |
| `material_flow_layer_0` (Initial Layer Flow) | Missing | a flow of the first layer |
| `wall_x_material_flow_layer_0` (Initial Layer Inner Wall Flow) | Missing | a flow of the inner walls of the first layer |
| `wall_0_material_flow_layer_0` (Initial Layer Outer Wall Flow) | Missing | a flow of the outer wall of the first layer |
| `skin_material_flow_layer_0` (Initial Layer Bottom Flow) | Missing | a flow of the skin of the first layer |
| `material_standby_temperature` (Standby Temperature) | Same | `filament.standby_temp` |
| `material_is_support_material` (Is support material) | Covered | `project.support_filament` |
| `gradual_flow_enabled` (Gradual flow enabled) | Missing | limit the change of the flow over time |
| `max_flow_acceleration` (Gradual flow max acceleration) | Missing | limit the change of the flow over time |
| `layer_0_max_flow_acceleration` (Initial layer max flow acceleration) | Missing | limit the change of the flow over time |
| `gradual_flow_discretisation_step_size` (Gradual flow discretisation step size) | Missing | limit the change of the flow over time |
| `material_pressure_advance_factor` (Pressure advance factor) | Covered | `filament.pressure_advance` (Cura hides it and uses it in the start G-code of some printers) |
| `material_max_flowrate` (Material Maximum Flow Rate) | Same | `filament.max_flow` |

### Speed

| Cura setting | Status | zslice |
|---|---|---|
| `speed_print` (Print Speed) | Covered | the importer gives its value to the speeds that a profile does not set |
| `speed_infill` (Infill Speed) | Same | `project.infill_speed` |
| `speed_wall` (Wall Speed) | Covered | the importer gives its value to speed_wall_0 and speed_wall_x |
| `speed_wall_0` (Outer Wall Speed) | Same | `project.outer_wall_speed` |
| `speed_wall_x` (Inner Wall Speed) | Same | `project.inner_wall_speed` |
| `speed_wall_0_roofing` (Top Surface Outer Wall Speed) | Missing | the speed of the outer wall of the top surface |
| `speed_wall_x_roofing` (Top Surface Inner Wall Speed) | Missing | the speed of the inner walls of the top surface |
| `speed_wall_0_flooring` (Bottom Surface Outer Wall Speed) | Missing | the speed of the outer wall of the bottom surface |
| `speed_wall_x_flooring` (Bottom Surface Inner Wall Speed) | Missing | the speed of the inner walls of the bottom surface |
| `speed_roofing` (Top Surface Skin Speed) | Missing | the speed of the top surface skin |
| `speed_flooring` (Bottom Surface Skin Speed) | Missing | the speed of the bottom surface skin |
| `speed_topbottom` (Top/Bottom Speed) | Same | `project.skin_speed` |
| `speed_support` (Support Speed) | Same | `project.support_speed` and `project.support_interface_speed` (the importer gives the Cura formulas) |
| `speed_support_infill` (Support Infill Speed) | Same | `project.support_speed` |
| `speed_support_interface` (Support Interface Speed) | Same | `project.support_interface_speed` |
| `speed_support_roof` (Support Roof Speed) | Same | `project.support_interface_speed` |
| `speed_support_bottom` (Support Floor Speed) | Missing | the speed of the support floor |
| `speed_prime_tower` (Prime Tower Speed) | Missing | the speed of the prime tower |
| `speed_travel` (Travel Speed) | Same | `machine.travel_speed` |
| `speed_layer_0` (Initial Layer Speed) | Same | `project.first_layer_speed` |
| `speed_print_layer_0` (Initial Layer Print Speed) | Covered | `project.first_layer_speed` |
| `speed_travel_layer_0` (Initial Layer Travel Speed) | Same | `machine.first_layer_travel_speed` |
| `skirt_brim_speed` (Skirt/Brim Speed) | Missing | the speed of the skirt and the brim |
| `speed_z_hop` (Z Hop Speed) | Missing | the speed of the z hop (zslice uses `machine.max_z_speed`) |
| `speed_slowdown_layers` (Number of Slower Layers) | Same | `project.slow_layers` |
| `speed_equalize_flow_width_factor` (Flow Equalization Ratio) | Missing | a faster speed for a thinner line |
| `acceleration_enabled` (Enable Acceleration Control) | Same | `machine.accel_control` |
| `acceleration_travel_enabled` (Enable Travel Acceleration) | Covered | `machine.travel_accel` |
| `acceleration_print` (Print Acceleration) | Covered | the feature accelerations (`machine.outer_wall_accel` and the others) |
| `acceleration_infill` (Infill Acceleration) | Same | `machine.infill_accel` |
| `acceleration_wall` (Wall Acceleration) | Covered | `machine.outer_wall_accel` and `machine.inner_wall_accel` |
| `acceleration_wall_0` (Outer Wall Acceleration) | Same | `machine.outer_wall_accel` |
| `acceleration_wall_x` (Inner Wall Acceleration) | Same | `machine.inner_wall_accel` |
| `acceleration_wall_0_roofing` (Top Surface Outer Wall Acceleration) | Missing | the acceleration of the outer wall of the top surface |
| `acceleration_wall_x_roofing` (Top Surface Inner Wall Acceleration) | Missing | the acceleration of the inner walls of the top surface |
| `acceleration_wall_0_flooring` (Bottom Surface Outer Wall Acceleration) | Missing | the acceleration of the outer wall of the bottom surface |
| `acceleration_wall_x_flooring` (Bottom Surface Inner Wall Acceleration) | Missing | the acceleration of the inner walls of the bottom surface |
| `acceleration_roofing` (Top Surface Skin Acceleration) | Missing | the acceleration of the top surface skin |
| `acceleration_flooring` (Bottom Surface Skin Acceleration) | Missing | the acceleration of the bottom surface skin |
| `acceleration_topbottom` (Top/Bottom Acceleration) | Same | `machine.skin_accel` |
| `acceleration_support` (Support Acceleration) | Missing | the acceleration of the support |
| `acceleration_support_infill` (Support Infill Acceleration) | Missing | the acceleration of the support lines |
| `acceleration_support_interface` (Support Interface Acceleration) | Missing | the acceleration of the support interface |
| `acceleration_support_roof` (Support Roof Acceleration) | Missing | the acceleration of the support roof |
| `acceleration_support_bottom` (Support Floor Acceleration) | Missing | the acceleration of the support floor |
| `acceleration_prime_tower` (Prime Tower Acceleration) | Missing | the acceleration of the prime tower |
| `acceleration_travel` (Travel Acceleration) | Same | `machine.travel_accel` |
| `acceleration_layer_0` (Initial Layer Acceleration) | Same | `machine.first_layer_accel` |
| `acceleration_print_layer_0` (Initial Layer Print Acceleration) | Covered | `machine.first_layer_accel` |
| `acceleration_travel_layer_0` (Initial Layer Travel Acceleration) | Missing | the acceleration of the travel of the first layer |
| `acceleration_skirt_brim` (Skirt/Brim Acceleration) | Missing | the acceleration of the skirt and the brim |
| `jerk_enabled` (Enable Jerk Control) | Missing | jerk commands (M205) for each feature |
| `jerk_travel_enabled` (Enable Travel Jerk) | Missing | jerk commands (M205) for the travel |
| `jerk_print` (Print Jerk) | Missing | the jerk of each feature |
| `jerk_infill` (Infill Jerk) | Missing | the jerk of each feature |
| `jerk_wall` (Wall Jerk) | Missing | the jerk of each feature |
| `jerk_wall_0` (Outer Wall Jerk) | Missing | the jerk of each feature |
| `jerk_wall_x` (Inner Wall Jerk) | Missing | the jerk of each feature |
| `jerk_wall_0_roofing` (Top Surface Outer Wall Jerk) | Missing | the jerk of each feature |
| `jerk_wall_x_roofing` (Top Surface Inner Wall Jerk) | Missing | the jerk of each feature |
| `jerk_wall_0_flooring` (Bottom Surface Outer Wall Jerk) | Missing | the jerk of each feature |
| `jerk_wall_x_flooring` (Bottom Surface Inner Wall Jerk) | Missing | the jerk of each feature |
| `jerk_roofing` (Top Surface Skin Jerk) | Missing | the jerk of each feature |
| `jerk_flooring` (Bottom Surface Skin Jerk) | Missing | the jerk of each feature |
| `jerk_topbottom` (Top/Bottom Jerk) | Missing | the jerk of each feature |
| `jerk_support` (Support Jerk) | Missing | the jerk of each feature |
| `jerk_support_infill` (Support Infill Jerk) | Missing | the jerk of each feature |
| `jerk_support_interface` (Support Interface Jerk) | Missing | the jerk of each feature |
| `jerk_support_roof` (Support Roof Jerk) | Missing | the jerk of each feature |
| `jerk_support_bottom` (Support Floor Jerk) | Missing | the jerk of each feature |
| `jerk_prime_tower` (Prime Tower Jerk) | Missing | the jerk of each feature |
| `jerk_travel` (Travel Jerk) | Missing | the jerk of each feature |
| `jerk_layer_0` (Initial Layer Jerk) | Missing | the jerk of each feature |
| `jerk_print_layer_0` (Initial Layer Print Jerk) | Missing | the jerk of each feature |
| `jerk_travel_layer_0` (Initial Layer Travel Jerk) | Missing | the jerk of each feature |
| `jerk_skirt_brim` (Skirt/Brim Jerk) | Missing | the jerk of each feature |

### Travel

| Cura setting | Status | zslice |
|---|---|---|
| `retraction_enable` (Enable Retraction) | Covered | `machine.retract_length` 0 is no retraction |
| `retract_at_layer_change` (Retract at Layer Change) | Same | `project.retract_layer_change` |
| `retraction_amount` (Retraction Distance) | Same | `machine.retract_length` |
| `retraction_speed` (Retraction Speed) | Same | `machine.retract_speed` |
| `retraction_retract_speed` (Retraction Retract Speed) | Covered | `machine.retract_speed` |
| `retraction_prime_speed` (Retraction Prime Speed) | Covered | `machine.retract_speed` |
| `retraction_extra_prime_amount` (Retraction Extra Prime Amount) | Missing | more plastic after a retraction |
| `retraction_min_travel` (Retraction Minimum Travel) | Same | `project.retract_min_travel` |
| `retraction_count_max` (Maximum Retraction Count) | Missing | a limit of retractions on one spot of filament |
| `retraction_extrusion_window` (Minimum Extrusion Distance Window) | Missing | a limit of retractions on one spot of filament |
| `retraction_combing` (Combing Mode) | Same | `project.combing` |
| `retraction_combing_max_distance` (Max Comb Distance With No Retract) | Same | `project.combing_max_distance` |
| `retraction_combing_avoid_distance` (Inside Travel Avoid Distance) | Missing | the distance of a combing way from the walls |
| `travel_retract_before_outer_wall` (Retract Before Outer Wall) | Missing | retract before the outer wall |
| `travel_avoid_other_parts` (Avoid Printed Parts When Traveling) | Missing | go around the other parts on a travel |
| `travel_avoid_supports` (Avoid Supports When Traveling) | Missing | go around the support on a travel |
| `travel_avoid_distance` (Travel Avoid Distance) | Missing | the distance of a travel from the parts |
| `layer_start_at_z_seam` (Layer Start at Z Seam) | Missing | start each layer at the seam |
| `layer_start_x` (Layer Start X) | Missing | the start point of each layer |
| `layer_start_y` (Layer Start Y) | Missing | the start point of each layer |
| `retraction_hop_enabled` (Z Hop When Retracted) | Covered | `project.z_hop` 0 is no hop |
| `retraction_hop_only_when_collides` (Z Hop Only Over Printed Parts) | Same | `project.z_hop_only_crossing` |
| `retraction_hop` (Z Hop Height) | Same | `project.z_hop` |
| `retraction_hop_after_extruder_switch` (Z Hop After Extruder Switch) | Missing | a z hop after a tool change |
| `retraction_hop_after_extruder_switch_height` (Z Hop After Extruder Switch Height) | Missing | a z hop after a tool change |

### Cooling

| Cura setting | Status | zslice |
|---|---|---|
| `cool_fan_enabled` (Enable Print Cooling) | Covered | `filament.fan_speed` 0 is no fan |
| `build_fan_full_at_height` (Build Volume Fan Speed at Height) | Not for zslice | the build volume fan of Ultimaker printers |
| `build_fan_full_layer` (Build Volume Fan Speed at Layer) | Not for zslice | the build volume fan of Ultimaker printers |
| `build_volume_fan_speed_0` (Initial Layers Build Volume Fan Speed) | Not for zslice | the build volume fan of Ultimaker printers |
| `build_volume_fan_speed` (Build Volume Fan Speed) | Not for zslice | the build volume fan of Ultimaker printers |
| `cool_fan_speed` (Fan Speed) | Same | `filament.fan_speed` |
| `cool_fan_speed_min` (Regular Fan Speed) | Same | `filament.fan_speed` |
| `cool_fan_speed_max` (Maximum Fan Speed) | Same | `filament.fan_max_speed` |
| `cool_min_layer_time_fan_speed_max` (Regular/Maximum Fan Speed Threshold) | Same | `filament.fan_boost_time` |
| `cool_fan_speed_0` (Initial Fan Speed) | Missing | a fan speed on the first layer other than 0 (zslice: 0, as the Cura default) |
| `cool_fan_full_at_height` (Regular Fan Speed at Height) | Covered | `filament.fan_off_layers` and `filament.fan_ramp_layers` |
| `cool_fan_full_layer` (Regular Fan Speed at Layer) | Covered | `filament.fan_off_layers` and `filament.fan_ramp_layers` (the importer converts it) |
| `cool_min_layer_time` (Minimum Layer Time) | Same | `filament.min_layer_time` |
| `cool_min_speed` (Minimum Speed) | Same | `filament.min_speed` |
| `cool_lift_head` (Lift Head) | Same | `filament.cooling_mode = lap` |
| `cool_min_temperature` (Small Layer Printing Temperature) | Missing | the lowest temperature of a nozzle that prints slower |
| `cool_during_extruder_switch` (Cooling during extruder switch) | Missing | the fan during a tool change |

### Support

| Cura setting | Status | zslice |
|---|---|---|
| `support_enable` (Generate Support) | Same | `project.support` |
| `support_extruder_nr` (Support Extruder) | Same | `project.support_filament` |
| `support_infill_extruder_nr` (Support Infill Extruder) | Same | `project.support_filament` |
| `support_extruder_nr_layer_0` (First Layer Support Extruder) | Missing | another filament for the first layer of the support |
| `support_interface_extruder_nr` (Support Interface Extruder) | Same | `project.support_interface_filament` |
| `support_roof_extruder_nr` (Support Roof Extruder) | Same | `project.support_interface_filament` |
| `support_bottom_extruder_nr` (Support Floor Extruder) | Same | `project.support_interface_filament` |
| `support_structure` (Support Structure) | Same | `project.support_style` |
| `support_tree_angle` (Maximum Branch Angle) | Same | `project.support_tree_angle` |
| `support_tree_branch_diameter` (Branch Diameter) | Missing | the diameter of a tree branch (zslice computes it from the load) |
| `support_tree_max_diameter` (Trunk Diameter) | Missing | the largest diameter of a tree branch |
| `support_tree_branch_diameter_angle` (Branch Diameter Angle) | Missing | the growth of a tree branch (zslice computes it from the load) |
| `support_tree_smooth_layers` (Branch Smoothing Layers) | Missing | smooth the tree branches |
| `support_z_seam_away_from_model` (Support Z Seam Away from Model) | Missing | the seams of the support away from the part |
| `support_z_seam_min_distance` (Min Z Seam Distance from Model) | Missing | the seams of the support away from the part |
| `support_type` (Support Placement) | Same | `project.support` |
| `support_tree_angle_slow` (Preferred Branch Angle) | Missing | the angle of a tree branch that does not need to move |
| `support_tree_max_diameter_increase_by_merges_when_support_to_model` (Diameter Increase To Model) | Missing | the growth of a tree branch that joins |
| `support_tree_min_height_to_model` (Minimum Height To Model) | Missing | a tree branch on the part |
| `support_tree_bp_diameter` (Initial Layer Diameter) | Covered | zslice gives a tree a foot from the load |
| `support_tree_top_rate` (Branch Density) | Missing | the number of tips of a tree |
| `support_tree_tip_diameter` (Tip Diameter) | Same | `project.support_tree_tip` |
| `support_tree_limit_branch_reach` (Limit Branch Reach) | Missing | the reach of a tree branch |
| `support_tree_branch_reach_limit` (Optimal Branch Range) | Missing | the reach of a tree branch |
| `support_tree_rest_preference` (Rest Preference) | Missing | a tree on the bed only, or on the part too |
| `support_angle` (Support Overhang Angle) | Same | `project.support_angle` |
| `support_pattern` (Support Pattern) | Missing | the pattern of the support |
| `support_wall_count` (Support Wall Line Count) | Missing | walls around the support |
| `support_wall_thickness` (Support Wall Thickness) | Missing | walls around the support |
| `support_enlarged_wall_thickness` (Support Enlarged Wall Thickness) | Missing | walls around the support |
| `support_wall_thickness_bottom_layers` (Support Wall Unenlarged Bottom Layers) | Missing | walls around the support |
| `support_wall_thickness_top_layers` (Support Wall Unenlarged Top Layers) | Missing | walls around the support |
| `support_wall_thickness_layer_smooth` (Support Wall Smooth Layer Width) | Missing | walls around the support |
| `support_infill_multiplier` (Support Infill Line Multiplier) | Missing | more support lines next to each other |
| `support_interface_wall_count` (Support Interface Wall Line Count) | Missing | walls around the support interface |
| `support_roof_wall_count` (Support Roof Wall Line Count) | Missing | walls around the support roof |
| `support_bottom_wall_count` (Support Bottom Wall Line Count) | Missing | walls around the support floor |
| `support_lightning_angle` (Support Lightning Angle) | Not for zslice | lightning support of a Cura beta |
| `support_lightning_overhang_angle` (Support Lightning Overhang Angle) | Not for zslice | lightning support of a Cura beta |
| `support_lightning_prune_angle` (Support Lightning Prune Angle) | Not for zslice | lightning support of a Cura beta |
| `support_lightning_straightening_angle` (Support Lightning Straightening Angle) | Not for zslice | lightning support of a Cura beta |
| `zig_zaggify_support` (Connect Support Lines) | Missing | join the support lines |
| `support_connect_zigzags` (Connect Support ZigZags) | Missing | join the zigzags of the support |
| `support_infill_rate` (Support Density) | Same | `project.support_density` |
| `support_line_distance` (Support Line Distance) | Same | `project.support_density` (a distance of the lines) |
| `support_initial_layer_line_distance` (Initial Layer Support Line Distance) | Missing | the support lines of the first layer |
| `support_infill_density_multiplier_initial_layer` (Support Infill Density Multiplier Initial Layer) | Missing | the support lines of the first layer |
| `support_infill_angles` (Support Infill Line Directions) | Missing | the angles of the support lines |
| `support_brim_enable` (Enable Inner Support Base) | Missing | a brim around the support |
| `support_outer_brim_enable` (Enable Outer Support Base) | Missing | a brim around the support |
| `support_brim_width` (Support Inner Brim Width) | Missing | a brim around the support |
| `support_brim_line_count` (Support Inner Brim Line Count) | Missing | a brim around the support |
| `support_brim_minimum_hole_area` (Minimum hole area in brim support) | Missing | a brim around the support |
| `support_base_height` (Support Base Height) | Missing | a base of the support |
| `support_inside_base_height` (Support Inside Base Height) | Missing | a base of the support |
| `support_outside_base_height` (Support Outside Base Height) | Missing | a base of the support |
| `support_base_width` (Support Base Width) | Missing | a base of the support |
| `support_base_inside_width` (Support Base Inside Width) | Missing | a base of the support |
| `support_base_outside_width` (Support Base Outside Width) | Missing | a base of the support |
| `support_base_curve_magnitude` (Support Base Slope) | Missing | a base of the support |
| `support_inside_base_curve_magnitude` (Support Inside Base Slope) | Missing | a base of the support |
| `support_outside_base_curve_magnitude` (Support Outside Base Slope) | Missing | a base of the support |
| `support_z_distance` (Support Z Distance) | Same | `project.support_z_gap_layers` (a count of layers) |
| `support_top_distance` (Support Top Distance) | Covered | `project.support_z_gap_layers` |
| `support_bottom_distance` (Support Bottom Distance) | Covered | `project.support_z_gap_layers` |
| `support_xy_distance` (Support X/Y Distance) | Same | `project.support_xy_gap` |
| `support_xy_overrides_z` (Support Distance Priority) | Missing | the XY gap or the Z gap first |
| `support_xy_distance_overhang` (Minimum Support X/Y Distance) | Missing | the XY gap at an overhang |
| `support_bottom_stair_step_height` (Support Stair Step Height) | Missing | the stairs of a support on the part |
| `support_bottom_stair_step_width` (Support Stair Step Maximum Width) | Missing | the stairs of a support on the part |
| `support_bottom_stair_step_min_slope` (Support Stair Step Minimum Slope Angle) | Missing | the stairs of a support on the part |
| `support_join_distance` (Support Join Distance) | Missing | join support areas that are near each other |
| `support_offset` (Support Horizontal Expansion) | Missing | make the support areas larger |
| `support_infill_sparse_thickness` (Support Infill Layer Thickness) | Missing | support lines of more than one layer |
| `gradual_support_infill_steps` (Gradual Support Infill Steps) | Missing | denser support under the part |
| `gradual_support_infill_step_height` (Gradual Support Infill Step Height) | Missing | denser support under the part |
| `minimum_support_area` (Minimum Support Area) | Covered | `project.support_min_ledge` (a width in place of an area) |
| `support_interface_enable` (Enable Support Interface) | Same | `project.support_interface_layers` 0 is no interface |
| `support_roof_enable` (Enable Support Roof) | Covered | `project.support_interface_layers` |
| `support_bottom_enable` (Enable Support Floor) | Missing | an interface on the part under the support |
| `support_interface_height` (Support Interface Thickness) | Same | `project.support_interface_layers` (a count of layers) |
| `support_roof_height` (Support Roof Thickness) | Covered | `project.support_interface_layers` |
| `support_bottom_height` (Support Floor Thickness) | Missing | an interface on the part under the support |
| `support_interface_density` (Support Interface Density) | Same | `project.support_interface_density` |
| `support_roof_density` (Support Roof Density) | Covered | `project.support_interface_density` |
| `support_roof_line_distance` (Support Roof Line Distance) | Covered | `project.support_interface_density` |
| `support_bottom_density` (Support Floor Density) | Missing | an interface on the part under the support |
| `support_bottom_line_distance` (Support Floor Line Distance) | Missing | an interface on the part under the support |
| `support_interface_pattern` (Support Interface Pattern) | Same | `project.support_interface_pattern` |
| `support_roof_pattern` (Support Roof Pattern) | Covered | `project.support_interface_pattern` |
| `support_bottom_pattern` (Support Floor Pattern) | Missing | an interface on the part under the support |
| `minimum_interface_area` (Minimum Support Interface Area) | Missing | no interface in small areas |
| `minimum_roof_area` (Minimum Support Roof Area) | Missing | no interface in small areas |
| `minimum_bottom_area` (Minimum Support Floor Area) | Missing | no interface in small areas |
| `support_interface_offset` (Support Interface Horizontal Expansion) | Missing | make the interface larger |
| `support_roof_offset` (Support Roof Horizontal Expansion) | Missing | make the interface larger |
| `support_bottom_offset` (Support Floor Horizontal Expansion) | Missing | make the interface larger |
| `support_interface_priority` (Support Interface Priority) | Missing | the interface or the part first where they touch |
| `support_interface_angles` (Support Interface Line Directions) | Missing | the angles of the interface lines |
| `support_roof_angles` (Support Roof Line Directions) | Missing | the angles of the interface lines |
| `support_bottom_angles` (Support Floor Line Directions) | Missing | the angles of the interface lines |
| `support_fan_enable` (Fan Speed Override) | Missing | a fan speed of the support |
| `support_supported_skin_fan_speed` (Supported Skin Fan Speed) | Missing | the fan over the support |
| `support_use_towers` (Use Towers) | Missing | towers under small overhangs |
| `support_tower_diameter` (Tower Diameter) | Missing | towers under small overhangs |
| `support_tower_maximum_supported_diameter` (Maximum Tower-Supported Diameter) | Missing | towers under small overhangs |
| `support_tower_roof_angle` (Tower Roof Angle) | Missing | towers under small overhangs |
| `support_mesh_drop_down` (Drop Down Support Mesh) | Missing | a support mesh down to the bed |
| `support_meshes_present` (Scene Has Support Meshes) | Not for zslice | a Cura flag of the scene |
| `support_paint_resolution` (Support Painting Precision) | Covered | zslice paints support areas as polygons |

### Build plate adhesion

| Cura setting | Status | zslice |
|---|---|---|
| `prime_blob_enable` (Enable Prime Blob) | Not for zslice | the prime blob of Ultimaker printers |
| `extruder_prime_pos_x` (Extruder Prime X Position) | Not for zslice | the prime blob of Ultimaker printers |
| `extruder_prime_pos_y` (Extruder Prime Y Position) | Not for zslice | the prime blob of Ultimaker printers |
| `adhesion_type` (Build Plate Adhesion Type) | Same | `project.skirt_loops` and `project.brim_width` (zslice has no raft) |
| `adhesion_extruder_nr` (Build Plate Adhesion Extruder) | Missing | another filament for the skirt and the brim |
| `skirt_brim_extruder_nr` (Skirt/Brim Extruder) | Missing | another filament for the skirt and the brim |
| `raft_base_extruder_nr` (Raft Base Extruder) | Missing | a raft |
| `raft_interface_extruder_nr` (Raft Middle Extruder) | Missing | a raft |
| `raft_surface_extruder_nr` (Raft Top Extruder) | Missing | a raft |
| `skirt_line_count` (Skirt Line Count) | Same | `project.skirt_loops` |
| `skirt_height` (Skirt Height) | Same | `project.skirt_layers` |
| `skirt_gap` (Skirt Distance) | Same | `project.skirt_distance` |
| `skirt_brim_minimal_length` (Skirt/Brim Minimum Length) | Missing | more skirt loops until the skirt has this length |
| `brim_width` (Brim Width) | Same | `project.brim_width` |
| `brim_line_count` (Brim Line Count) | Same | `project.brim_width` (the importer multiplies by the line width) |
| `brim_gap` (Brim Distance) | Missing | a gap between the brim and the part |
| `brim_replaces_support` (Brim Replaces Support) | Missing | the brim under the support |
| `brim_location` (Brim Location) | Same | `project.brim_location` |
| `brim_inside_margin` (Brim Avoid Margin) | Missing | a brim inside a hole only near the edge |
| `brim_smart_ordering` (Smart Brim) | Missing | the order of the brim loops |
| `raft_margin` (Raft Extra Margin) | Missing | a raft |
| `raft_base_margin` (Raft Base Extra Margin) | Missing | a raft |
| `raft_interface_margin` (Raft Middle Extra Margin) | Missing | a raft |
| `raft_surface_margin` (Raft Top Extra Margin) | Missing | a raft |
| `raft_remove_inside_corners` (Remove Raft Inside Corners) | Missing | a raft |
| `raft_base_remove_inside_corners` (Remove Raft Base Inside Corners) | Missing | a raft |
| `raft_interface_remove_inside_corners` (Remove Raft Middle Inside Corners) | Missing | a raft |
| `raft_surface_remove_inside_corners` (Remove Raft Top Inside Corners) | Missing | a raft |
| `raft_smoothing` (Raft Smoothing) | Missing | a raft |
| `raft_base_smoothing` (Raft Base Smoothing) | Missing | a raft |
| `raft_interface_smoothing` (Raft Middle Smoothing) | Missing | a raft |
| `raft_surface_smoothing` (Raft Top Smoothing) | Missing | a raft |
| `raft_airgap` (Raft Air Gap) | Missing | a raft |
| `layer_0_z_overlap` (Initial Layer Z Overlap) | Missing | a raft |
| `raft_base_thickness` (Raft Base Thickness) | Missing | a raft |
| `raft_base_line_width` (Raft Base Line Width) | Missing | a raft |
| `raft_base_line_spacing` (Raft Base Line Spacing) | Missing | a raft |
| `raft_base_infill_overlap` (Raft Base Infill Overlap Percentage) | Missing | a raft |
| `raft_base_infill_overlap_mm` (Raft Base Infill Overlap) | Missing | a raft |
| `raft_interface_layers` (Raft Middle Layers) | Missing | a raft |
| `raft_interface_thickness` (Raft Middle Thickness) | Missing | a raft |
| `raft_interface_line_width` (Raft Middle Line Width) | Missing | a raft |
| `raft_interface_line_spacing` (Raft Middle Spacing) | Missing | a raft |
| `raft_interface_z_offset` (Raft Interface Z Offset) | Missing | a raft |
| `raft_interface_infill_overlap` (Raft Interface Infill Overlap Percentage) | Missing | a raft |
| `raft_interface_infill_overlap_mm` (Raft Interface Infill Overlap) | Missing | a raft |
| `raft_surface_layers` (Raft Top Layers) | Missing | a raft |
| `raft_surface_thickness` (Raft Top Layer Thickness) | Missing | a raft |
| `raft_surface_line_width` (Raft Top Line Width) | Missing | a raft |
| `raft_surface_line_spacing` (Raft Top Spacing) | Missing | a raft |
| `raft_surface_z_offset` (Raft Surface Z Offset) | Missing | a raft |
| `raft_surface_monotonic` (Monotonic Raft Top Surface Order) | Missing | a raft |
| `raft_surface_infill_overlap` (Raft Surface Infill Overlap Percentage) | Missing | a raft |
| `raft_surface_infill_overlap_mm` (Raft Surface Infill Overlap) | Missing | a raft |
| `raft_wall_count` (Raft Wall Count) | Missing | a raft |
| `raft_base_wall_count` (Raft Base Wall Count) | Missing | a raft |
| `raft_interface_wall_count` (Raft Middle Wall Count) | Missing | a raft |
| `raft_surface_wall_count` (Raft Top Wall Count) | Missing | a raft |
| `raft_speed` (Raft Print Speed) | Missing | a raft |
| `raft_base_speed` (Raft Base Print Speed) | Missing | a raft |
| `raft_interface_speed` (Raft Middle Print Speed) | Missing | a raft |
| `raft_surface_speed` (Raft Top Print Speed) | Missing | a raft |
| `raft_acceleration` (Raft Print Acceleration) | Missing | a raft |
| `raft_base_acceleration` (Raft Base Print Acceleration) | Missing | a raft |
| `raft_interface_acceleration` (Raft Middle Print Acceleration) | Missing | a raft |
| `raft_surface_acceleration` (Raft Top Print Acceleration) | Missing | a raft |
| `raft_jerk` (Raft Print Jerk) | Missing | a raft |
| `raft_base_jerk` (Raft Base Print Jerk) | Missing | a raft |
| `raft_interface_jerk` (Raft Middle Print Jerk) | Missing | a raft |
| `raft_surface_jerk` (Raft Top Print Jerk) | Missing | a raft |
| `raft_fan_speed` (Raft Fan Speed) | Missing | a raft |
| `raft_base_fan_speed` (Raft Base Fan Speed) | Missing | a raft |
| `raft_interface_fan_speed` (Raft Middle Fan Speed) | Missing | a raft |
| `raft_surface_fan_speed` (Raft Top Fan Speed) | Missing | a raft |
| `raft_flow` (Raft Flow) | Missing | a raft |
| `raft_base_flow` (Raft Base Flow) | Missing | a raft |
| `raft_interface_flow` (Raft Interface Flow) | Missing | a raft |
| `raft_surface_flow` (Raft Surface Flow) | Missing | a raft |
| `machine_scan_first_layer` (Scan the first layer) | Not for zslice | the first layer scan of Ultimaker printers |

### Dual extrusion

| Cura setting | Status | zslice |
|---|---|---|
| `prime_tower_enable` (Enable Prime Tower) | Same | `project.prime_tower` |
| `prime_tower_mode` (Prime Tower Type) | Missing | the kind of prime tower (normal or interleaved) |
| `prime_tower_size` (Prime Tower Size) | Same | `project.prime_tower_width` |
| `prime_tower_min_volume` (Prime Tower Minimum Volume) | Covered | `machine.flush_volume` and `project.flush_multiplier` |
| `prime_tower_max_bridging_distance` (Prime Tower Maximum Bridging Distance) | Missing | the bridges of an interleaved prime tower |
| `prime_tower_min_shell_thickness` (Prime Tower Minimum Shell Thickness) | Missing | the wall of the prime tower |
| `prime_tower_position_x` (Prime Tower X Position) | Same | `project.prime_tower_x` |
| `prime_tower_position_y` (Prime Tower Y Position) | Same | `project.prime_tower_y` |
| `prime_tower_wipe_enabled` (Wipe Inactive Nozzle on Prime Tower) | Covered | zslice wipes on the prime tower |
| `prime_tower_brim_enable` (Prime Tower Base) | Missing | a brim around the prime tower |
| `prime_tower_base_size` (Prime Tower Base Size) | Missing | a base of the prime tower |
| `prime_tower_base_height` (Prime Tower Base Height) | Missing | a base of the prime tower |
| `prime_tower_base_curve_magnitude` (Prime Tower Base Slope) | Missing | a base of the prime tower |
| `prime_tower_raft_base_line_spacing` (Prime Tower Raft Line Spacing) | Missing | a raft |
| `ooze_shield_enabled` (Enable Ooze Shield) | Missing | a shield around the part for the oozing of the other nozzle |
| `ooze_shield_angle` (Ooze Shield Angle) | Missing | a shield around the part for the oozing of the other nozzle |
| `ooze_shield_dist` (Ooze Shield Distance) | Missing | a shield around the part for the oozing of the other nozzle |
| `switch_extruder_retraction_amount` (Nozzle Switch Retraction Distance) | Missing | the retraction of a tool change |
| `switch_extruder_retraction_speeds` (Nozzle Switch Retraction Speed) | Missing | the retraction of a tool change |
| `switch_extruder_retraction_speed` (Nozzle Switch Retract Speed) | Missing | the retraction of a tool change |
| `switch_extruder_prime_speed` (Nozzle Switch Prime Speed) | Missing | the retraction of a tool change |
| `switch_extruder_extra_prime_amount` (Nozzle Switch Extra Prime Amount) | Missing | the retraction of a tool change |
| `interlocking_enable` (Generate Interlocking Structure) | Covered | `project.paint_anchor_depth` (zslice roots a painted feature in the part) |
| `interlocking_beam_width` (Interlocking Beam Width) | Covered | `project.paint_anchor_depth` |
| `interlocking_orientation` (Interlocking Structure Orientation) | Covered | `project.paint_anchor_depth` |
| `interlocking_beam_layer_count` (Interlocking Beam Layer Count) | Covered | `project.paint_anchor_depth` |
| `interlocking_depth` (Interlocking Depth) | Covered | `project.paint_anchor_depth` |
| `interlocking_boundary_avoidance` (Interlocking Boundary Avoidance) | Covered | `project.paint_anchor_depth` |
| `multi_material_paint_resolution` (Multi-material Precision) | Covered | zslice splits the paint at the triangles of the paint |
| `multi_material_paint_depth` (Multi-material Depth) | Covered | zslice colors a painted top or bottom within the shell thickness |

### Mesh fixes

| Cura setting | Status | zslice |
|---|---|---|
| `meshfix_union_all` (Union Overlapping Volumes) | Missing | union of the overlapping volumes of a mesh |
| `meshfix_union_all_remove_holes` (Remove All Holes) | Missing | remove the holes of each layer |
| `meshfix_extensive_stitching` (Extensive Stitching) | Covered | zslice joins the cut segments by the mesh edges |
| `meshfix_keep_open_polygons` (Keep Disconnected Faces) | Missing | keep open outlines |
| `multiple_mesh_overlap` (Merged Meshes Overlap) | Missing | an overlap of the meshes of a plate |
| `carve_multiple_volumes` (Remove Mesh Intersection) | Covered | the parts of a plate slice as their own jobs |
| `alternate_carve_order` (Alternate Mesh Removal) | Covered | the parts of a plate slice as their own jobs |
| `remove_empty_first_layers` (Remove Empty First Layers) | Covered | zslice starts at the bottom of the part |
| `meshfix_maximum_resolution` (Maximum Resolution) | Same | `engine.resolution` |
| `meshfix_maximum_travel_resolution` (Maximum Travel Resolution) | Covered | `engine.resolution` |
| `meshfix_maximum_deviation` (Maximum Deviation) | Covered | `engine.resolution` |
| `meshfix_maximum_extrusion_area_deviation` (Maximum Extrusion Area Deviation) | Covered | `engine.resolution` |
| `meshfix_fluid_motion_enabled` (Enable Fluid Motion) | Missing | smooth the corners of short segments |
| `meshfix_fluid_motion_shift_distance` (Fluid Motion Shift Distance) | Missing | smooth the corners of short segments |
| `meshfix_fluid_motion_small_distance` (Fluid Motion Small Distance) | Missing | smooth the corners of short segments |
| `meshfix_fluid_motion_angle` (Fluid Motion Angle) | Missing | smooth the corners of short segments |

### Special modes

| Cura setting | Status | zslice |
|---|---|---|
| `print_sequence` (Print Sequence) | Missing | one part at a time |
| `user_defined_print_order_enabled` (Set Print Sequence Manually) | Missing | the order of the parts |
| `infill_mesh` (Infill Mesh) | Same | a modifier volume of a plate (the importer reads it) |
| `infill_mesh_order` (Mesh Processing Rank) | Same | the order of the modifier volumes |
| `cutting_mesh` (Cutting Mesh) | Missing | a cutting mesh |
| `mold_enabled` (Mold) | Missing | a mold around the part |
| `mold_width` (Minimal Mold Width) | Missing | a mold around the part |
| `mold_roof_height` (Mold Roof Height) | Missing | a mold around the part |
| `mold_angle` (Mold Angle) | Missing | a mold around the part |
| `support_mesh` (Support Mesh) | Covered | the support areas of zslice |
| `anti_overhang_mesh` (Anti Overhang Mesh) | Covered | the support areas of zslice (an area that blocks support) |
| `magic_mesh_surface_mode` (Surface Mode) | Missing | print the surface of a mesh only |
| `magic_spiralize` (Spiralize Outer Contour) | Same | `project.spiral_vase` |
| `smooth_spiralized_contours` (Smooth Spiralized Contours) | Missing | spiral vase mode |
| `relative_extrusion` (Relative Extrusion) | Covered | zslice writes relative extrusion (M83) |

### Experimental

| Cura setting | Status | zslice |
|---|---|---|
| `slicing_tolerance` (Slicing Tolerance) | Covered | zslice cuts each layer at its middle |
| `infill_enable_travel_optimization` (Infill Travel Optimization) | Covered | zslice orders the infill lines in the nearest order |
| `material_flow_temp_graph` (Flow Temperature Graph) | Missing | a temperature for each flow |
| `minimum_polygon_circumference` (Minimum Polygon Circumference) | Missing | drop small outlines |
| `support_skip_some_zags` (Break Up Support In Chunks) | Missing | break points in the support |
| `support_skip_zag_per_mm` (Support Chunk Size) | Missing | break points in the support |
| `support_zag_skip_count` (Support Chunk Line Count) | Missing | break points in the support |
| `draft_shield_enabled` (Enable Draft Shield) | Missing | a draft shield around the part |
| `draft_shield_dist` (Draft Shield X/Y Distance) | Missing | a draft shield around the part |
| `draft_shield_height_limitation` (Draft Shield Limitation) | Missing | a draft shield around the part |
| `draft_shield_height` (Draft Shield Height) | Missing | a draft shield around the part |
| `conical_overhang_enabled` (Make Overhang Printable) | Missing | make an overhang printable |
| `conical_overhang_angle` (Maximum Model Angle) | Missing | make an overhang printable |
| `conical_overhang_hole_size` (Maximum Overhang Hole Area) | Missing | make an overhang printable |
| `coasting_enable` (Enable Coasting) | Covered | `project.coasting_volume` (more than 0) |
| `coasting_volume` (Coasting Volume) | Same | `project.coasting_volume` |
| `coasting_min_volume` (Minimum Volume Before Coasting) | Covered | `project.coasting_volume` (a path coasts if it has twice this volume) |
| `coasting_speed` (Coasting Speed) | Same | `project.coasting_speed` |
| `cross_infill_pocket_size` (Cross 3D Pocket Size) | Missing | the cross infill pattern |
| `cross_infill_density_image` (Cross Infill Density Image) | Missing | an image of the infill density |
| `cross_support_density_image` (Cross Fill Density Image for Support) | Missing | an image of the support density |
| `support_conical_enabled` (Enable Conical Support) | Missing | conical support |
| `support_conical_angle` (Conical Support Angle) | Missing | conical support |
| `support_conical_min_width` (Conical Support Minimum Width) | Missing | conical support |
| `magic_fuzzy_skin_enabled` (Fuzzy Skin) | Covered | `project.fuzzy_skin` (outer_wall or outside) |
| `magic_fuzzy_skin_outside_only` (Fuzzy Skin Outside Only) | Covered | `project.fuzzy_skin = outside` |
| `magic_fuzzy_skin_thickness` (Fuzzy Skin Thickness) | Same | `project.fuzzy_skin_thickness` |
| `magic_fuzzy_skin_point_density` (Fuzzy Skin Density) | Covered | `project.fuzzy_skin_point_distance` |
| `magic_fuzzy_skin_point_dist` (Fuzzy Skin Point Distance) | Same | `project.fuzzy_skin_point_distance` |
| `flow_rate_max_extrusion_offset` (Flow Rate Compensation Max Extrusion Offset) | Missing | a flow offset for fast lines |
| `flow_rate_extrusion_offset_factor` (Flow Rate Compensation Factor) | Missing | a flow offset for fast lines |
| `adaptive_layer_height_enabled` (Use Adaptive Layers) | Missing | adaptive layers (zslice has layer height overrides for ranges) |
| `adaptive_layer_height_variation` (Adaptive Layers Maximum Variation) | Missing | adaptive layers |
| `adaptive_layer_height_variation_step` (Adaptive Layers Variation Step Size) | Missing | adaptive layers |
| `adaptive_layer_height_threshold` (Adaptive Layers Topography Size) | Missing | adaptive layers |
| `wall_overhang_angle` (Overhanging Wall Angle) | Covered | `project.overhang_wall_threshold` (a share of the line width over air, in place of an angle) |
| `cool_min_layer_time_overhang` (Minimum Layer Time with Overhang) | Missing | a minimum layer time for overhangs |
| `cool_min_layer_time_overhang_min_segment_length` (Minimum Overhang Segment Length) | Missing | a minimum layer time for overhangs |
| `seam_overhang_angle` (Seam Overhanging Wall Angle) | Missing | no seam over an overhang (the zslice hidden seam avoids overhangs) |
| `wall_overhang_speed_factors` (Overhanging Wall Speeds) | Covered | `project.overhang_wall_speed` (one speed for all overhangs) |
| `bridge_settings_enabled` (Enable Bridge Settings) | Same | `project.bridges` |
| `bridge_wall_max_deviation` (Maximum Bridge Deviation) | Missing | the bridge walls |
| `bridge_wall_min_length` (Minimum Bridge Wall Length) | Missing | the bridge walls |
| `bridge_skin_support_threshold` (Bridge Skin Support Threshold) | Missing | the bridge skin |
| `bridge_wall_coast` (Bridge Wall Coasting) | Missing | the bridge walls |
| `bridge_wall_speed` (Bridge Wall Speed) | Missing | the speed of the bridge walls |
| `bridge_wall_material_flow` (Bridge Wall Flow) | Missing | the flow of the bridge walls |
| `bridge_skin_speed` (Bridge Skin Speed) | Same | `project.bridge_speed` |
| `bridge_skin_material_flow` (Bridge Skin Flow) | Same | `project.bridge_flow` |
| `bridge_skin_density` (Bridge Skin Density) | Missing | the density of the bridge skin |
| `bridge_fan_speed` (Bridge Fan Speed) | Same | `project.bridge_fan` |
| `bridge_interlace_lines` (Interlace Bridge Lines) | Missing | the bridge skin |
| `bridge_enable_more_layers` (Bridge Has Multiple Layers) | Missing | the layers over a bridge |
| `bridge_skin_speed_2` (Bridge Second Skin Speed) | Missing | the layers over a bridge |
| `bridge_skin_material_flow_2` (Bridge Second Skin Flow) | Missing | the layers over a bridge |
| `bridge_skin_density_2` (Bridge Second Skin Density) | Missing | the layers over a bridge |
| `bridge_fan_speed_2` (Bridge Second Skin Fan Speed) | Missing | the layers over a bridge |
| `bridge_skin_speed_3` (Bridge Third Skin Speed) | Missing | the layers over a bridge |
| `bridge_skin_material_flow_3` (Bridge Third Skin Flow) | Missing | the layers over a bridge |
| `bridge_skin_density_3` (Bridge Third Skin Density) | Missing | the layers over a bridge |
| `bridge_fan_speed_3` (Bridge Third Skin Fan Speed) | Missing | the layers over a bridge |
| `clean_between_layers` (Wipe Nozzle Between Layers) | Missing | a wipe on a brush between the layers |
| `max_extrusion_before_wipe` (Material Volume Between Wipes) | Missing | a wipe on a brush between the layers |
| `wipe_retraction_enable` (Wipe Retraction Enable) | Missing | a wipe on a brush between the layers |
| `wipe_retraction_amount` (Wipe Retraction Distance) | Missing | a wipe on a brush between the layers |
| `wipe_retraction_extra_prime_amount` (Wipe Retraction Extra Prime Amount) | Missing | a wipe on a brush between the layers |
| `wipe_retraction_speed` (Wipe Retraction Speed) | Missing | a wipe on a brush between the layers |
| `wipe_retraction_retract_speed` (Wipe Retraction Retract Speed) | Missing | a wipe on a brush between the layers |
| `wipe_retraction_prime_speed` (Wipe Retraction Prime Speed) | Missing | a wipe on a brush between the layers |
| `wipe_pause` (Wipe Pause) | Missing | a wipe on a brush between the layers |
| `wipe_hop_enable` (Wipe Z Hop) | Missing | a wipe on a brush between the layers |
| `wipe_hop_amount` (Wipe Z Hop Height) | Missing | a wipe on a brush between the layers |
| `wipe_hop_speed` (Wipe Hop Speed) | Missing | a wipe on a brush between the layers |
| `wipe_brush_pos_x` (Wipe Brush X Position) | Missing | a wipe on a brush between the layers |
| `wipe_repeat_count` (Wipe Repeat Count) | Missing | a wipe on a brush between the layers |
| `wipe_move_distance` (Wipe Move Distance) | Missing | a wipe on a brush between the layers |
| `small_hole_max_size` (Small Hole Max Size) | Missing | slower walls in small holes |
| `small_feature_max_length` (Small Feature Max Length) | Missing | slower walls in small features |
| `small_feature_speed_factor` (Small Feature Speed) | Missing | slower walls in small features |
| `small_feature_speed_factor_0` (Small Feature Initial Layer Speed) | Missing | slower walls in small features |
| `material_alternate_walls` (Alternate Wall Directions) | Missing | the walls of two filaments in turn |
| `group_outer_walls` (Group Outer Walls) | Missing | print the outer walls of a layer together |
| `retraction_during_travel_ratio` (Retraction During Travel Move) | Covered | `project.retract_wipe` |
| `keep_retracting_during_travel` (Keep Retracting During Travel) | Covered | `project.retract_wipe` |
| `prime_during_travel_ratio` (Prime During Travel Move) | Missing | a push back during the travel |
| `scarf_joint_seam_length` (Scarf Seam Length) | Missing | a scarf seam |
| `scarf_joint_seam_start_height_ratio` (Scarf Seam Start Height) | Missing | a scarf seam |
| `scarf_split_distance` (Scarf Seam Step Length) | Missing | a scarf seam |
| `wall_0_start_speed_ratio` (Outer Wall Start Speed Ratio) | Missing | a slow start of the outer wall |
| `wall_0_acceleration` (Outer Wall Start Acceleration) | Missing | a slow start of the outer wall |
| `wall_0_end_speed_ratio` (Outer Wall End Speed Ratio) | Missing | a slow end of the outer wall |
| `wall_0_deceleration` (Outer Wall End Deceleration) | Missing | a slow end of the outer wall |
| `wall_0_speed_split_distance` (Outer Wall Speed Split Distance) | Missing | a slow start and end of the outer wall |
| `minimum_infill_line_length` (Minimum Infill Line Length) | Missing | drop short infill lines |
| `material_delta_temperature_roofing` (Temperature Delta Top Surface) | Missing | another temperature for the top surface |

### Machine

| Cura setting | Status | zslice |
|---|---|---|
| `build_volume_fan_nr` (Build volume fan number) | Not for zslice | a fan number of the Ultimaker S-line build volume fan |
| `machine_name` (Machine Type) | Same | `machine.name` |
| `machine_show_variants` (Show Machine Variants) | Not for zslice | a Cura UI switch for the variants list |
| `machine_start_gcode` (Start G-code) | Same | `machine.start_gcode` (the importer converts the variables) |
| `machine_end_gcode` (End G-code) | Same | `machine.end_gcode` |
| `material_guid` (Material GUID) | Not for zslice | a Cura material database id |
| `material_type` (Material Type) | Same | `filament.material` |
| `material_brand` (Material Brand) | Covered | `filament.name` has the brand |
| `material_diameter` (Diameter) | Same | `filament.diameter` |
| `material_bed_temp_wait` (Wait for Build Plate Heatup) | Covered | zslice waits for the bed (M190) before the first layer |
| `material_print_temp_wait` (Wait for Nozzle Heatup) | Covered | zslice waits for the nozzle (M109) before the first layer |
| `material_print_temp_prepend` (Include Material Temperatures) | Covered | zslice heats before a start G-code that does not heat |
| `material_bed_temp_prepend` (Include Build Plate Temperature) | Covered | zslice heats before a start G-code that does not heat |
| `machine_width` (Machine Width) | Same | `machine.bed_size_x` |
| `machine_depth` (Machine Depth) | Same | `machine.bed_size_y` |
| `machine_height` (Machine Height) | Same | `machine.max_height` |
| `machine_shape` (Build Plate Shape) | Covered | the printer library has the shape of the bed (round beds) |
| `machine_buildplate_type` (Build Plate Type) | Same | `machine.bed_type` |
| `machine_heated_bed` (Has Heated Build Plate) | Covered | `filament.bed_temp` 0 is no heat |
| `machine_heated_build_volume` (Has Build Volume Temperature Stabilization) | Missing | a heated chamber: zslice has `machine.chamber_temp` for the simulation only |
| `machine_always_write_active_tool` (Always Write Active Tool) | Missing | write T0 on a printer with one extruder |
| `machine_center_is_zero` (Is Center Origin) | Same | `machine.origin_x` and `machine.origin_y` (the importer sets them) |
| `machine_extruder_count` (Number of Extruders) | Same | `machine.nozzles` (1 or 2) |
| `extruders_enabled_count` (Number of Extruders That Are Enabled) | Covered | the filaments of the plate |
| `machine_nozzle_tip_outer_diameter` (Outer Nozzle Diameter) | Same | `machine.nozzle_tip_radius` |
| `machine_nozzle_expansion_angle` (Nozzle Angle) | Same | `machine.nozzle_cone_angle` |
| `machine_heat_zone_length` (Heat Zone Length) | Not for zslice | for the Cura model of the oozing of a nozzle that waits |
| `machine_nozzle_temp_enabled` (Enable Nozzle Temperature Control) | Covered | `filament.nozzle_temp` 0 is no heat |
| `machine_nozzle_heat_up_speed` (Heat Up Speed) | Missing | the time to heat a nozzle, for the warm up of the next tool |
| `machine_nozzle_cool_down_speed` (Cool Down Speed) | Missing | the time to cool a nozzle, for the cool down of a tool that waits |
| `machine_min_cool_heat_time_window` (Minimal Time Standby Temperature) | Missing | the least time to cool a tool that waits |
| `machine_gcode_flavor` (G-code Flavor) | Same | `machine.gcode_flavor` |
| `machine_firmware_retract` (Firmware Retraction) | Missing | G10 and G11 for the retraction |
| `machine_extruders_share_heater` (Extruders Share Heater) | Not for zslice | Ultimaker hardware with two feeders on one heater |
| `machine_extruders_share_nozzle` (Extruders Share Nozzle) | Not for zslice | Ultimaker hardware with two feeders on one nozzle |
| `machine_extruders_shared_nozzle_initial_retraction` (Shared Nozzle Initial Retraction) | Not for zslice | Ultimaker hardware with two feeders on one nozzle |
| `machine_disallowed_areas` (Disallowed Areas) | Missing | areas of the bed where no part can go |
| `nozzle_disallowed_areas` (Nozzle Disallowed Areas) | Missing | areas of the bed where a nozzle cannot go |
| `machine_head_with_fans_polygon` (Machine Head & Fan Polygon) | Missing | the size of the head, for one-at-a-time print order |
| `gantry_height` (Gantry Height) | Missing | the height of the gantry, for one-at-a-time print order |
| `machine_time_estimation_factor` (Print Time Estimation Factor) | Not for zslice | zslice plans each move with the motion limits for the time |
| `machine_nozzle_id` (Nozzle ID) | Covered | `machine.nozzle_diameter` and `machine.nozzle_type` |
| `machine_nozzle_size` (Nozzle Diameter) | Same | `machine.nozzle_diameter` |
| `machine_use_extruder_offset_to_offset_coords` (Offset with Extruder) | Covered | zslice moves the second nozzle in the G-code of the printer (`machine.nozzles`) |
| `machine_start_gcode_first` (Start GCode must be first) | Missing | the start G-code before the heat commands |
| `extruder_prime_pos_z` (Extruder Prime Z Position) | Not for zslice | the prime blob of Ultimaker printers |
| `extruder_prime_pos_abs` (Absolute Extruder Prime Position) | Not for zslice | the prime blob of Ultimaker printers |
| `machine_max_feedrate_x` (Maximum Speed X) | Same | `machine.max_speed_x` |
| `machine_max_feedrate_y` (Maximum Speed Y) | Same | `machine.max_speed_y` |
| `machine_max_feedrate_z` (Maximum Speed Z) | Same | `machine.max_z_speed` |
| `machine_max_feedrate_e` (Maximum Speed E) | Missing | the speed limit of the extruder, for the time estimate |
| `machine_max_acceleration_x` (Maximum Acceleration X) | Same | `machine.max_accel_x` |
| `machine_max_acceleration_y` (Maximum Acceleration Y) | Same | `machine.max_accel_y` |
| `machine_max_acceleration_z` (Maximum Acceleration Z) | Same | `machine.max_z_accel` |
| `machine_max_acceleration_e` (Maximum Filament Acceleration) | Missing | the acceleration limit of the extruder, for the time estimate |
| `machine_acceleration` (Default Acceleration) | Same | `machine.max_accel` |
| `machine_max_jerk_xy` (Default X-Y Jerk) | Same | `machine.corner_speed` |
| `machine_max_jerk_z` (Default Z Jerk) | Missing | the jerk of Z, for the time estimate |
| `machine_max_jerk_e` (Default Filament Jerk) | Missing | the jerk of the extruder, for the time estimate |
| `machine_steps_per_mm_x` (Steps per Millimeter (X)) | Not for zslice | firmware facts that CuraEngine does not use |
| `machine_steps_per_mm_y` (Steps per Millimeter (Y)) | Not for zslice | firmware facts that CuraEngine does not use |
| `machine_steps_per_mm_z` (Steps per Millimeter (Z)) | Not for zslice | firmware facts that CuraEngine does not use |
| `machine_steps_per_mm_e` (Steps per Millimeter (E)) | Not for zslice | firmware facts that CuraEngine does not use |
| `machine_endstop_positive_direction_x` (X Endstop in Positive Direction) | Not for zslice | firmware facts that CuraEngine does not use |
| `machine_endstop_positive_direction_y` (Y Endstop in Positive Direction) | Not for zslice | firmware facts that CuraEngine does not use |
| `machine_endstop_positive_direction_z` (Z Endstop in Positive Direction) | Not for zslice | firmware facts that CuraEngine does not use |
| `machine_minimum_feedrate` (Minimum Feedrate) | Missing | the lowest speed of the firmware, for the time estimate |
| `machine_feeder_wheel_diameter` (Feeder Wheel Diameter) | Not for zslice | firmware facts that CuraEngine does not use |
| `machine_scale_fan_speed_zero_to_one` (Scale Fan Speed To 0-1) | Missing | write the fan speed from 0 to 1 (M106 S0.5) for some firmware |
| `reset_flow_duration` (Reset flow duration) | Not for zslice | a Cura setting of the flow sensor of Ultimaker printers |
| `extruder_nr` (Extruder) | Covered | `filament.nozzle` (the nozzle of a filament) |
| `machine_extruder_change_duration` (Extruder Change duration) | Same | `machine.change_time` |
| `machine_extruder_cooling_fan_number` (Extruder Print Cooling Fan) | Missing | the fan of each extruder |
| `machine_extruder_end_code` (Extruder End G-Code) | Same | `machine.change_gcode` (one text for all changes) |
| `machine_extruder_end_code_duration` (Extruder End G-Code Duration) | Covered | `machine.change_time` |
| `machine_extruder_end_pos_abs` (Extruder End Position Absolute) | Not for zslice | the park place of an extruder of an Ultimaker printer |
| `machine_extruder_end_pos_x` (Extruder End Position X) | Not for zslice | the park place of an extruder of an Ultimaker printer |
| `machine_extruder_end_pos_y` (Extruder End Position Y) | Not for zslice | the park place of an extruder of an Ultimaker printer |
| `machine_extruder_prestart_code` (Extruder Prestart G-Code) | Missing | G-code before a tool heats |
| `machine_extruder_start_code` (Extruder Start G-Code) | Same | `machine.change_gcode` (one text for all changes) |
| `machine_extruder_start_code_duration` (Extruder Start G-Code Duration) | Covered | `machine.change_time` |
| `machine_extruder_start_pos_abs` (Extruder Start Position Absolute) | Not for zslice | the park place of an extruder of an Ultimaker printer |
| `machine_extruder_start_pos_x` (Extruder Start Position X) | Not for zslice | the park place of an extruder of an Ultimaker printer |
| `machine_extruder_start_pos_y` (Extruder Start Position Y) | Not for zslice | the park place of an extruder of an Ultimaker printer |
| `machine_nozzle_head_distance` (Nozzle Length) | Not for zslice | the height of a nozzle under the head of an Ultimaker printer |
| `machine_nozzle_offset_x` (Nozzle X Offset) | Missing | the X offset of a second nozzle |
| `machine_nozzle_offset_y` (Nozzle Y Offset) | Missing | the Y offset of a second nozzle |

### Command line

| Cura setting | Status | zslice |
|---|---|---|
| `center_object` (Center Object) | Same | `project.placement` |
| `mesh_position_x` (Mesh Position X) | Same | `project.placement = file` |
| `mesh_position_y` (Mesh Position Y) | Same | `project.placement = file` |
| `mesh_position_z` (Mesh Position Z) | Same | `project.placement = file` |
| `mesh_rotation_matrix` (Mesh Rotation Matrix) | Covered | the rotation of a part on the plate |
| `material_density` (Material density) | Same | `filament.density` |
| `material_id` (Cura Material ID) | Not for zslice | a Cura material database id |
| `material_name` (Material Name) | Same | `filament.name` |
| `material_spool_cost` (Material Spool Cost) | Same | `filament.price_per_kg` |
| `material_spool_weight` (Material Spool Weight) | Covered | `filament.price_per_kg` |

### Print process reporting

| Cura setting | Status | zslice |
|---|---|---|
| `ppr_enable` (Enable Print Process Reporting) | Not for zslice | the print process reports of Ultimaker printers |
| `flow_warn_limit` (Flow Warning) | Not for zslice | the print process reports of Ultimaker printers |
| `flow_anomaly_limit` (Flow Limit) | Not for zslice | the print process reports of Ultimaker printers |
| `print_temp_warn_limit` (Print temperature Warning) | Not for zslice | the print process reports of Ultimaker printers |
| `print_temp_anomaly_limit` (Print temperature Limit) | Not for zslice | the print process reports of Ultimaker printers |
| `bv_temp_warn_limit` (Build Volume temperature Warning) | Not for zslice | the print process reports of Ultimaker printers |
| `bv_temp_anomaly_limit` (Build Volume temperature Limit) | Not for zslice | the print process reports of Ultimaker printers |

## OrcaSlicer

The print, printer, and filament settings first, by status. The settings of resin printers, the options of the command line, and the G-code variables are at the end.

### Same

| OrcaSlicer setting | zslice |
|---|---|
| `alternate_extra_wall` (Alternate extra wall) | `project.alternate_extra_wall` |
| `auxiliary_fan` (Auxiliary part cooling fan) | `machine.part_fan_air` (the simulation counts the air of all fans) |
| `bottom_shell_layers` (Bottom shell layers) | `project.bottom_thickness` (a count of layers) |
| `bottom_shell_thickness` (Bottom shell thickness) | `project.bottom_thickness` |
| `bottom_surface_pattern` (Bottom surface pattern) | `project.skin_pattern` |
| `bridge_flow` (Bridge flow ratio) | `project.bridge_flow` |
| `bridge_speed` (External) | `project.bridge_speed` |
| `brim_type` (Brim type) | `project.brim_location` |
| `brim_width` (Brim width) | `project.brim_width` |
| `chamber_temperature` (Chamber temperature) | `machine.chamber_temp` |
| `change_filament_gcode` (Change filament G-code) | `machine.change_gcode` |
| `close_fan_the_first_x_layers` (No cooling for the first) | `filament.fan_off_layers` |
| `curr_bed_type` (Bed type) | `machine.bed_type` |
| `default_acceleration` (Normal printing) | `machine.max_accel` |
| `default_bed_type` (Default bed type) | `machine.bed_type` |
| `default_filament_colour` (Default color) | `filament.color` |
| `default_jerk` (Default) | `machine.corner_speed` |
| `default_junction_deviation` (Junction Deviation) | `machine.corner_speed` (as a corner speed) |
| `detect_thin_wall` (Detect thin walls) | `project.thin_walls` |
| `elefant_foot_compensation` (Elephant foot compensation) | `project.first_layer_xy_offset` |
| `enable_prime_tower` (Enable) | `project.prime_tower` |
| `enable_support` (Enable support) | `project.support` |
| `extruder_printable_area` (Extruder printable area) | `machine.nozzle2_min_x` and `machine.nozzle1_max_x` |
| `extruder_printable_height` (Extruder printable height) | `machine.nozzle1_max_height` and `machine.nozzle2_max_height` |
| `fan_cooling_layer_time` (Layer time) | `filament.fan_boost_time` |
| `fan_max_speed` (Fan speed) | `filament.fan_max_speed` |
| `fan_min_speed` (Fan speed) | `filament.fan_speed` |
| `filament_colour` (Color) | `filament.color` |
| `filament_cost` (Price) | `filament.price_per_kg` |
| `filament_density` (Density) | `filament.density` |
| `filament_diameter` (Diameter) | `filament.diameter` |
| `filament_end_gcode` (End G-code) | `filament.end_gcode` (at the end of the print) |
| `filament_flow_ratio` (Flow ratio) | `filament.flow_ratio` |
| `filament_is_support` (Support material) | `project.support_filament` |
| `filament_max_volumetric_speed` (Max volumetric speed) | `filament.max_flow` |
| `filament_shrink` (Shrinkage (XY)) | `filament.shrinkage_xy` |
| `filament_shrinkage_compensation_z` (Shrinkage (Z)) | `filament.shrinkage_z` |
| `filament_start_gcode` (Start G-code) | `filament.start_gcode` (at the start of the print) |
| `filament_type` (Type) | `filament.material` |
| `flush_into_objects` (Flush into this object) | `project.flush_into_hidden` |
| `flush_multiplier` (Flush multiplier) | `project.flush_multiplier` |
| `full_fan_speed_layer` (Full fan speed at layer) | `filament.fan_ramp_layers` (the importer converts it) |
| `fuzzy_skin_point_distance` (Fuzzy skin point distance) | `project.fuzzy_skin_point_distance` |
| `fuzzy_skin_thickness` (Fuzzy skin thickness) | `project.fuzzy_skin_thickness` |
| `gcode_flavor` (G-code flavor) | `machine.gcode_flavor` |
| `gcode_label_objects` (Label objects) | `machine.label_objects` |
| `hole_to_polyhole` (Convert holes to polyholes) | `project.polyholes` |
| `idle_temperature` (Idle temperature) | `filament.standby_temp` |
| `infill_combination` (Infill combination) | `project.infill_layers` |
| `infill_direction` (Sparse infill direction) | `project.infill_angle` |
| `infill_wall_overlap` (Infill/wall overlap) | `project.infill_overlap` |
| `initial_layer_acceleration` (First layer) | `machine.first_layer_accel` |
| `initial_layer_line_width` (First layer) | `project.first_layer_line_width` |
| `initial_layer_print_height` (First layer height) | `project.first_layer_height` |
| `initial_layer_speed` (First layer) | `project.first_layer_speed` |
| `initial_layer_travel_speed` (First layer travel speed) | `machine.first_layer_travel_speed` |
| `inner_wall_acceleration` (Inner wall) | `machine.inner_wall_accel` |
| `inner_wall_speed` (Inner wall) | `project.inner_wall_speed` |
| `internal_solid_infill_acceleration` (Internal solid infill) | `machine.skin_accel` |
| `internal_solid_infill_pattern` (Internal solid infill pattern) | `project.skin_pattern` |
| `internal_solid_infill_speed` (Internal solid infill) | `project.skin_speed` |
| `ironing_flow` (Ironing flow) | `project.ironing_flow` |
| `ironing_inset` (Ironing inset) | `project.ironing_inset` |
| `ironing_spacing` (Ironing line spacing) | `project.ironing_spacing` |
| `ironing_speed` (Ironing speed) | `project.ironing_speed` |
| `ironing_type` (Ironing type) | `project.ironing` |
| `layer_height` (Layer height) | `project.layer_height` |
| `lightning_overhang_angle` (Lightning overhang angle) | `project.lightning_angle` |
| `line_width` (Default) | `project.line_width` |
| `machine_end_gcode` (End G-code) | `machine.end_gcode` |
| `machine_max_acceleration_extruding` | `machine.max_accel` |
| `machine_max_acceleration_travel` | `machine.travel_accel` |
| `machine_max_junction_deviation` | `machine.corner_speed` (as a corner speed) |
| `machine_start_gcode` (Start G-code) | `machine.start_gcode` |
| `machine_tool_change_time` (Tool change time) | `machine.change_time` |
| `manual_filament_change` (Manual Filament Change) | `machine.filament_change = pause` |
| `max_travel_detour_distance` (Avoid crossing walls - Max detour length) | `project.combing_max_distance` |
| `min_bead_width` (Minimum wall width) | `project.min_bead_width` |
| `min_feature_size` (Minimum feature size) | `project.min_feature_size` |
| `minimum_sparse_infill_area` (Minimum sparse infill threshold) | `project.solid_infill_width` (a width in place of an area) |
| `mmu_segmented_region_interlocking_depth` (Interlocking depth of a segmented region) | `project.paint_anchor_depth` |
| `nozzle_diameter` (Nozzle diameter) | `machine.nozzle_diameter` |
| `nozzle_temperature` (Other layers) | `filament.nozzle_temp` |
| `nozzle_temperature_initial_layer` (First layer) | `filament.first_layer_nozzle_temp` |
| `nozzle_type` (Nozzle type) | `machine.nozzle_type` |
| `outer_wall_acceleration` (Outer wall) | `machine.outer_wall_accel` |
| `outer_wall_speed` (Outer wall) | `project.outer_wall_speed` (a ratio of `machine.max_speed`) |
| `overhang_fan_speed` (Overhangs and external bridges fan speed) | `project.bridge_fan` |
| `pressure_advance` (Pressure advance) | `filament.pressure_advance` |
| `prime_tower_width` (Width) | `project.prime_tower_width` |
| `printable_area` (Printable area) | `machine.bed_size_x` and `machine.bed_size_y` (the printer library has the shape) |
| `printable_height` (Printable height) | `machine.max_height` |
| `printer_model` (Printer type) | `machine.model` |
| `printer_structure` (Printer structure) | `machine.kinematics` |
| `reduce_crossing_wall` (Avoid crossing walls) | `project.combing` |
| `reduce_infill_retraction` (Reduce infill retraction) | `project.combing` (no retraction inside the part) |
| `resolution` (Resolution) | `engine.resolution` |
| `retract_lift_enforce` (On surfaces) | `project.z_hop_only_crossing` |
| `retract_when_changing_layer` (Retract on layer change) | `project.retract_layer_change` |
| `retraction_length` (Length) | `machine.retract_length` |
| `retraction_minimum_travel` (Travel distance threshold) | `project.retract_min_travel` |
| `retraction_speed` (Retraction speed) | `machine.retract_speed` |
| `seam_position` (Seam position) | `project.seam` |
| `single_extruder_multi_material` (Single Extruder Multi Material) | `machine.filament_change = tool` (one nozzle, many filaments) |
| `skirt_distance` (Skirt distance) | `project.skirt_distance` |
| `skirt_height` (Skirt height) | `project.skirt_layers` |
| `skirt_loops` (Skirt loops) | `project.skirt_loops` |
| `slice_closing_radius` (Slice gap closing radius) | `engine.gap_closing` |
| `slow_down_layer_time` (Layer time) | `filament.min_layer_time` |
| `slow_down_layers` (Number of slow layers) | `project.slow_layers` |
| `slow_down_min_speed` (Min print speed) | `filament.min_speed` |
| `solid_infill_direction` (Solid infill direction) | `project.skin_angle` |
| `sparse_infill_acceleration` (Sparse infill) | `machine.infill_accel` |
| `sparse_infill_density` (Sparse infill density) | `project.infill_density` |
| `sparse_infill_pattern` (Sparse infill pattern) | `project.infill_pattern` |
| `sparse_infill_speed` (Sparse infill) | `project.infill_speed` |
| `spiral_mode` (Spiral vase) | `project.spiral_vase` |
| `support_angle` (Pattern angle) | `project.support_angle` |
| `support_base_pattern_spacing` (Base pattern spacing) | `project.support_density` (a density in place of a spacing) |
| `support_filament` (Support/raft base) | `project.support_filament` |
| `support_interface_filament` (Support/raft interface) | `project.support_interface_filament` |
| `support_interface_pattern` (Interface pattern) | `project.support_interface_pattern` |
| `support_interface_spacing` (Top interface spacing) | `project.support_interface_density` (a density in place of a spacing) |
| `support_interface_speed` (Support interface) | `project.support_interface_speed` |
| `support_interface_top_layers` (Top interface layers) | `project.support_interface_layers` |
| `support_object_xy_distance` (Support/object XY distance) | `project.support_xy_gap` |
| `support_on_build_plate_only` (On build plate only) | `project.support = buildplate` |
| `support_remove_small_overhang` (Ignore small overhangs) | `project.support_min_ledge` |
| `support_speed` (Support) | `project.support_speed` |
| `support_style` (Style) | `project.support_style` |
| `support_threshold_angle` (Threshold angle) | `project.support_angle` |
| `support_top_z_distance` (Top Z distance) | `project.support_z_gap_layers` (a count of layers) |
| `support_type` (Type) | `project.support_style` |
| `thumbnails` (G-code thumbnails) | `machine.thumbnails` |
| `time_cost` (Time cost) | `machine.hour_rate` |
| `top_bottom_infill_wall_overlap` (Top/Bottom solid infill/wall overlap) | `project.skin_overlap` |
| `top_shell_layers` (Top shell layers) | `project.top_thickness` (a count of layers) |
| `top_shell_thickness` (Top shell thickness) | `project.top_thickness` |
| `top_surface_acceleration` (Top surface) | `machine.skin_accel` |
| `top_surface_pattern` (Top surface pattern) | `project.skin_pattern` |
| `top_surface_speed` (Top surface) | `project.skin_speed` |
| `travel_acceleration` (Travel) | `machine.travel_accel` |
| `travel_speed` (Travel) | `machine.travel_speed` |
| `travel_speed_z` (Z travel) | `machine.max_z_speed` |
| `tree_support_branch_angle` (Tree support branch angle) | `project.support_tree_angle` |
| `tree_support_branch_angle_organic` (Tree support branch angle) | `project.support_tree_angle` |
| `tree_support_branch_distance` (Tree support branch distance) | `project.support_tree_spacing` |
| `tree_support_branch_distance_organic` (Tree support branch distance) | `project.support_tree_spacing` |
| `tree_support_tip_diameter` (Tip Diameter) | `project.support_tree_tip` |
| `wall_distribution_count` (Wall distribution count) | `project.wall_distribution_count` |
| `wall_generator` (Wall generator) | `project.wall_generator` |
| `wall_loops` (Wall loops) | `project.wall_count` |
| `wall_transition_angle` (Wall transitioning threshold angle) | `project.wall_transition_angle` |
| `wall_transition_length` (Wall transition length) | `project.wall_transition_length` |
| `wipe` (Wipe while retracting) | `project.retract_wipe` |
| `wipe_tower_x` (Position X) | `project.prime_tower_x` |
| `wipe_tower_y` (Position Y) | `project.prime_tower_y` |
| `xy_contour_compensation` (X-Y contour compensation) | `filament.xy_offset` |
| `xy_hole_compensation` (X-Y hole compensation) | `filament.hole_xy_offset` |
| `z_hop` (Z-hop height) | `project.z_hop` |
| `zaa_enabled` (Z contouring enabled) | `project.slope_smoothing` |

### Covered

| OrcaSlicer setting | zslice |
|---|---|
| `adaptive_bed_mesh_margin` (Mesh margin) | the start G-code variables of the first layer box |
| `bed_custom_model` (Bed custom model) | the printer library has the bed models |
| `bed_custom_texture` (Bed custom texture) | the printer library has the bed textures |
| `bed_mesh_max` (Bed mesh max) | the start G-code variable of the first layer box (first_layer_print_max) |
| `bed_mesh_min` (Bed mesh min) | the start G-code variable of the first layer box (first_layer_print_min) |
| `bed_mesh_probe_distance` (Probe point distance) | the start G-code variables of the first layer box |
| `best_object_pos` (Best object position) | `project.placement` |
| `cool_plate_temp` (Other layers) | `filament.bed_temp` |
| `cool_plate_temp_initial_layer` (First layer) | `filament.first_layer_bed_temp` |
| `deretraction_speed` (Deretraction speed) | `machine.retract_speed` |
| `enable_overhang_bridge_fan` (Force cooling for overhangs and bridges) | `project.bridges` |
| `enable_overhang_speed` (Slow down for overhangs) | `project.overhang_wall_speed` (below 100 %) |
| `enable_pressure_advance` (Enable pressure advance) | `filament.pressure_advance` 0 is off |
| `eng_plate_temp` (Other layers) | `filament.bed_temp` |
| `eng_plate_temp_initial_layer` (First layer) | `filament.first_layer_bed_temp` |
| `exclude_object` (Exclude objects) | `machine.label_objects` (EXCLUDE_OBJECT on Klipper) |
| `extruder` (Extruder) | `filament.nozzle` |
| `extruder_colour` (Extruder Color) | `filament.color` |
| `filament_soluble` (Soluble material) | `project.support_filament` |
| `filament_vendor` (Vendor) | `filament.name` has the brand |
| `filter_out_gap_fill` (Filter out tiny gaps) | `project.gap_fill` |
| `flush_volumes_matrix` (Purging volumes) | `machine.flush_volume` and the colors of the filaments |
| `flush_volumes_vector` (Purging volumes - load/unload volumes) | `machine.flush_volume` |
| `fuzzy_skin` (Fuzzy skin) | `project.fuzzy_skin` (external is outer_wall; no fuzzy skin on all walls) |
| `fuzzy_skin_first_layer` (Apply fuzzy skin to first layer) | `project.fuzzy_skin` (the first layer stays smooth) |
| `gap_fill_target` (Apply gap fill) | `project.gap_fill` |
| `hole_to_polyhole_threshold` (Polyhole detection margin) | `project.polyholes` (a hole within 3 % of a circle) |
| `hot_plate_temp` (Other layers) | `filament.bed_temp` |
| `hot_plate_temp_initial_layer` (First layer) | `filament.first_layer_bed_temp` |
| `infill_anchor` (Sparse infill anchor length) | `project.infill_connect` |
| `infill_anchor_max` (Maximum length of the infill anchor) | `project.infill_connect` |
| `inherits` (Inherits profile) | the profiles of the printer library resolve the inherits chain |
| `initial_layer_infill_speed` (First layer infill) | `project.first_layer_speed` |
| `initial_layer_min_bead_width` (First layer minimum wall width) | `project.min_bead_width` |
| `interface_shells` (Interface shells) | the parts of a plate slice as their own jobs |
| `interlocking_beam` (Use beam interlocking) | `project.paint_anchor_depth` |
| `interlocking_beam_layer_count` (Interlocking beam layers) | `project.paint_anchor_depth` |
| `interlocking_beam_width` (Interlocking beam width) | `project.paint_anchor_depth` |
| `interlocking_boundary_avoidance` (Interlocking boundary avoidance) | `project.paint_anchor_depth` |
| `interlocking_depth` (Interlocking depth) | `project.paint_anchor_depth` |
| `interlocking_orientation` (Interlocking direction) | `project.paint_anchor_depth` |
| `lightning_prune_angle` (Prune angle) | `project.lightning_angle` |
| `lightning_straightening_angle` (Straightening angle) | `project.lightning_angle` |
| `machine_load_filament_time` (Filament load time) | `machine.change_time` |
| `machine_pause_gcode` (Pause G-code) | M600 or PAUSE (`machine.filament_change`) |
| `machine_unload_filament_time` (Filament unload time) | `machine.change_time` |
| `mmu_segmented_region_max_width` (Maximum width of a segmented region) | the label depth (src/label.zig) |
| `nozzle_hrc` (Nozzle HRC) | `machine.nozzle_type` |
| `nozzle_temperature_range_high` (Max) | the G-code variable nozzle_temperature_range_high |
| `nozzle_temperature_range_low` (Min) | the G-code variable nozzle_temperature_range_low |
| `overhang_1_4_speed` (10%) | `project.overhang_wall_speed` (one speed for all overhangs over `project.overhang_wall_threshold`) |
| `overhang_2_4_speed` (25%) | `project.overhang_wall_speed` (one speed for all overhangs over `project.overhang_wall_threshold`) |
| `overhang_3_4_speed` (50%) | `project.overhang_wall_speed` (one speed for all overhangs over `project.overhang_wall_threshold`) |
| `overhang_4_4_speed` (75%) | `project.overhang_wall_speed` (one speed for all overhangs over `project.overhang_wall_threshold`) |
| `overhang_fan_threshold` (Overhang cooling activation threshold) | `project.overhang_wall_threshold` (for the fan of `project.overhang_wall_fan`) |
| `precise_z_height` (Precise Z height) | zslice cuts each layer at its middle and ends at the height of the part |
| `printer_variant` (Printer variant) | `machine.nozzle_diameter` |
| `required_nozzle_HRC` (Required nozzle HRC) | `machine.nozzle_type` (a filament with fiber needs a hard nozzle) |
| `retract_length_toolchange` (Retraction Length (Toolchange)) | `machine.change_gcode` and the Bambu Lab presets |
| `slow_down_for_layer_cooling` (Slow printing down for better layer cooling) | `filament.min_layer_time` 0 is no slow down |
| `spaghetti_detector` (Enable spaghetti detector) | zslice turns the spaghetti detector of a Bambu Lab printer on (M981) |
| `standby_temperature_delta` (Temperature variation) | the G-code variable standby_temperature_delta |
| `supertack_plate_temp` (Other layers) | `filament.bed_temp` (one bed temperature for the plate of the printer) |
| `supertack_plate_temp_initial_layer` (First layer) | `filament.first_layer_bed_temp` |
| `support_bottom_z_distance` (Bottom Z distance) | `project.support_z_gap_layers` |
| `support_chamber_temp_control` (Support controlling chamber temperature) | `machine.chamber_temp` |
| `support_multi_bed_types` (Support multi bed types) | `machine.bed_type` |
| `temperature_vitrification` (Softening temperature) | the glass points of the simulation (src/print_sim.zig) |
| `textured_cool_plate_temp` (Other layers) | `filament.bed_temp` |
| `textured_cool_plate_temp_initial_layer` (First layer) | `filament.first_layer_bed_temp` |
| `textured_plate_temp` (Other layers) | `filament.bed_temp` |
| `textured_plate_temp_initial_layer` (First layer) | `filament.first_layer_bed_temp` |
| `thumbnails_format` (Format of G-code thumbnails) | `machine.thumbnails` (PNG) |
| `tree_support_auto_brim` (Auto brim width) | zslice gives a tree a foot from the load |
| `tree_support_branch_diameter` (Tree support branch diameter) | zslice computes the branch diameter from the load |
| `tree_support_branch_diameter_angle` (Branch Diameter Angle) | zslice computes the branch diameter from the load |
| `tree_support_branch_diameter_organic` (Tree support branch diameter) | zslice computes the branch diameter from the load |
| `use_relative_e_distances` (Use relative E distances) | zslice writes relative extrusion (M83) |
| `wall_sequence` (Walls printing order) | `project.wall_order` (inner first or outer first; no inner-outer-inner order) |
| `wall_transition_filter_deviation` (Wall transitioning filter margin) | zslice uses the default (a quarter of the nozzle) |
| `wipe_distance` (Wipe distance) | `project.retract_wipe` |
| `z_hop_types` (Z-hop type) | `project.z_hop` (a straight lift) |
| `zaa_dont_alternate_fill_direction` (Don't alternate fill direction) | `project.slope_smoothing` |
| `zaa_min_z` (Minimum Z height) | `project.slope_smoothing_min_width` |
| `zaa_minimize_perimeter_height` (Minimize wall height angle) | `project.slope_smoothing` |

### Missing

| OrcaSlicer setting | zslice |
|---|---|
| `accel_to_decel_enable` (Enable accel_to_decel) | the accel to decel limit of Klipper |
| `accel_to_decel_factor` (accel_to_decel) | the accel to decel limit of Klipper |
| `activate_air_filtration` (Activate air filtration) | Activate air filtration |
| `activate_air_filtration_during_print` |  |
| `activate_air_filtration_on_completion` |  |
| `activate_chamber_temp_control` (Activate temperature control) | Activate temperature control |
| `adaptive_infill_gradient` (Adaptive gradient) | Adaptive gradient |
| `adaptive_infill_interior_density` (Interior density) | Interior density |
| `adaptive_infill_mode` (Adaptive density (experimental)) | Adaptive density (experimental) |
| `adaptive_layer_height` (Adaptive layer height) | adaptive layers |
| `adaptive_pressure_advance` (Enable adaptive pressure advance (beta)) | Enable adaptive pressure advance (beta) |
| `adaptive_pressure_advance_bridges` (Static pressure advance for bridges) | Static pressure advance for bridges |
| `adaptive_pressure_advance_model` (Adaptive pressure advance measurements (beta)) | Adaptive pressure advance measurements (beta) |
| `adaptive_pressure_advance_overhangs` (Enable adaptive pressure advance within features (beta)) | Enable adaptive pressure advance within features (beta) |
| `additional_cooling_fan_speed` (Fan speed) | Fan speed |
| `additional_fan_full_speed_layer` (Full fan speed at layer) | Full fan speed at layer |
| `align_infill_direction_to_model` (Align directions to model) | Align directions to model |
| `bed_exclude_area` (Excluded bed area) | areas of the bed where no part can go |
| `bed_exclude_volume_mode` (Collision volume behavior) | volumes where no part can go |
| `bed_exclude_volumes` (Toolhead collision volumes) | volumes where no part can go |
| `bed_temperature_formula` (Bed temperature type) | Bed temperature type |
| `before_layer_change_gcode` (Before layer change G-code) | G-code before each layer change |
| `bottom_color_penetration_layers` (Bottom paint penetration layers) | Bottom paint penetration layers |
| `bottom_layer_direction` (Bottom layer direction) | Bottom layer direction |
| `bottom_solid_infill_flow_ratio` (Bottom surface flow ratio) | Bottom surface flow ratio |
| `bottom_surface_density` (Bottom surface density) | Bottom surface density |
| `bottom_surface_filament_id` (Bottom surface) | Bottom surface |
| `bottom_surface_fill_order` (Bottom surface fill order) | Bottom surface fill order |
| `bridge_acceleration` (Bridge) | Bridge |
| `bridge_angle` (External bridge infill direction) | External bridge infill direction |
| `bridge_density` (External bridge density) | External bridge density |
| `bridge_line_width` (Bridge) | Bridge |
| `bridge_no_support` (Don't support bridges) | Don't support bridges |
| `bridge_volumetric_flow` (External) | External |
| `brim_ears` (Brim ears) | Brim ears |
| `brim_ears_detection_length` (Brim ear detection radius) | Brim ear detection radius |
| `brim_ears_max_angle` (Brim ear max angle) | Brim ear max angle |
| `brim_ears_outer_only` (Brim ears outer only) | Brim ears outer only |
| `brim_filament_id` (Brim) | Brim |
| `brim_flow_ratio` (Brim flow ratio) | Brim flow ratio |
| `brim_object_gap` (Brim-object gap) | Brim-object gap |
| `brim_use_efc_outline` (Brim follows compensated outline) | Brim follows compensated outline |
| `center_of_surface_pattern` (Center surface pattern on) | Center surface pattern on |
| `chamber_minimal_temperature` (Minimal) | Minimal |
| `change_extrusion_role_gcode` (Change extrusion role G-code) | Change extrusion role G-code |
| `close_additional_fan_first_x_layers` (For the first) | For the first |
| `combine_brims` (Combine brims) | Combine brims |
| `complete_print_exhaust_fan_speed` (Fan speed) | Fan speed |
| `cooling_filter_enabled` (Use cooling filter) | Use cooling filter |
| `cooling_tube_length` (Cooling tube length) | Cooling tube length |
| `cooling_tube_retraction` (Cooling tube position) | Cooling tube position |
| `counterbore_hole_bridging` (Bridge counterbore holes) | Bridge counterbore holes |
| `default_nozzle_volume_type` (Default Nozzle Volume Type.) | Default Nozzle Volume Type. |
| `deretract_speed_extruder_change` (Deretraction speed (extruder change)) | Deretraction speed (extruder change) |
| `detect_narrow_internal_solid_infill` (Detect narrow internal solid infills) | Detect narrow internal solid infills |
| `detect_overhang_wall` (Detect overhang walls) | Detect overhang walls |
| `disable_m73` (Disable set remaining print time) | no M73 progress lines |
| `dont_filter_internal_bridges` (Filter out small internal bridges) | Filter out small internal bridges |
| `dont_slow_down_outer_wall` (Don't slow down outer walls) | Don't slow down outer walls |
| `draft_shield` (Draft shield) | Draft shield |
| `during_print_exhaust_fan_speed` (Fan speed) | Fan speed |
| `elefant_foot_compensation_layers` (Elephant foot compensation layers) | Elephant foot compensation layers |
| `elefant_foot_layers_density` (Elephant foot layers density) | Elephant foot layers density |
| `emit_machine_limits_to_gcode` (Emit limits to G-code) | write the motion limits (M201, M203) at the start |
| `enable_arc_fitting` (Arc fitting) | arcs (G2, G3) in the G-code |
| `enable_extra_bridge_layer` (Extra bridge layers (beta)) | Extra bridge layers (beta) |
| `enable_filament_dynamic_map` (Enable filament dynamic map) | Enable filament dynamic map |
| `enable_filament_ramming` (Enable filament ramming) | Enable filament ramming |
| `enable_long_retraction_when_cut` |  |
| `enable_mixed_color_sublayer` (Mixed color sublayer) | Mixed color sublayer |
| `enable_power_loss_recovery` (Power Loss Recovery) | power loss recovery (M413) |
| `enable_pre_heating` |  |
| `enable_tower_interface_cooldown_during_tower` (Cool down from interface boost during prime tower) | Cool down from interface boost during prime tower |
| `enable_tower_interface_features` (Enable tower interface features) | Enable tower interface features |
| `enable_volumetric_speeds` (Volumetric speeds) | Volumetric speeds |
| `enforce_support_layers` (Enforce support for the first) | Enforce support for the first |
| `ensure_vertical_shell_thickness` (Ensure vertical shell thickness) | Ensure vertical shell thickness |
| `exclude_object_tolerance` (Outline tolerance) | Outline tolerance |
| `extra_brim_width` (Extra brim width) | Extra brim width |
| `extra_loading_move` (Extra loading distance) | Extra loading distance |
| `extra_perimeters_on_overhangs` (Extra perimeters on overhangs) | Extra perimeters on overhangs |
| `extra_solid_infills` (Insert solid layers) | Insert solid layers |
| `extruder_ams_count` (Extruder AMS count) | Extruder AMS count |
| `extruder_bed_exclude_volumes` (Extruder collision volumes) | volumes where a nozzle cannot go |
| `extruder_clearance_dist_to_rod` (Distance to rod) | the size of the head, for one-at-a-time print order |
| `extruder_clearance_height_to_lid` (Height to lid) | the size of the head, for one-at-a-time print order |
| `extruder_clearance_height_to_rod` (Height to rod) | the size of the head, for one-at-a-time print order |
| `extruder_clearance_radius` (Radius) | the size of the head, for one-at-a-time print order |
| `extruder_max_nozzle_count` |  |
| `extruder_nozzle_count` (extruder nozzle count) | extruder nozzle count |
| `extruder_nozzle_stats` (Extruder nozzle stats) | Extruder nozzle stats |
| `extruder_nozzle_volume_type` (Extruder nozzle volume type) | Extruder nozzle volume type |
| `extruder_offset` (Extruder offset) | the X and Y offset of a second nozzle |
| `extruder_type` (Type) | direct drive or Bowden, for the retraction |
| `extruder_variant_list` (Extruder variant list) | Extruder variant list |
| `extrusion_rate_smoothing_external_perimeter_only` (Apply only on external features) | Apply only on external features |
| `fan_direction` (Fan direction) | Fan direction |
| `fan_kickstart` (Fan kick-start time) | Fan kick-start time |
| `fan_speedup_overhangs` (Only overhangs) | Only overhangs |
| `fan_speedup_time` (Fan speed-up time) | Fan speed-up time |
| `farthest_point_timelapse` (Farthest point timelapse) | Farthest point timelapse |
| `filament_adaptive_volumetric_speed` (Adaptive volumetric speed) | Adaptive volumetric speed |
| `filament_adhesiveness_category` (Adhesiveness Category) | Adhesiveness Category |
| `filament_change_extrusion_role_gcode` (Change extrusion role G-code (filament)) | Change extrusion role G-code (filament) |
| `filament_change_length` (Filament ramming length) | Filament ramming length |
| `filament_change_length_nc` (Hotend change) | Hotend change |
| `filament_colour_type` |  |
| `filament_cooling_before_tower` (Wipe tower cooling) | Wipe tower cooling |
| `filament_cooling_final_speed` (Speed of the last cooling move) | Speed of the last cooling move |
| `filament_cooling_initial_speed` (Speed of the first cooling move) | Speed of the first cooling move |
| `filament_cooling_moves` (Number of cooling moves) | Number of cooling moves |
| `filament_dev_ams_drying_ams_limitations` |  |
| `filament_dev_ams_drying_heat_distortion_temperature` |  |
| `filament_dev_ams_drying_temperature` |  |
| `filament_dev_ams_drying_time` |  |
| `filament_dev_chamber_drying_bed_temperature` |  |
| `filament_dev_chamber_drying_time` |  |
| `filament_dev_drying_cooling_temperature` |  |
| `filament_dev_drying_softening_temperature` |  |
| `filament_extruder_compatibility` (Filament-extruder compatibility) | Filament-extruder compatibility |
| `filament_extruder_id` (Filament extruder id) | Filament extruder id |
| `filament_extruder_variant` (Filament's extruder variant) | Filament's extruder variant |
| `filament_flush_temp` (Flush temperature) | Flush temperature |
| `filament_flush_temp_fast` (Flush temperature) | Flush temperature |
| `filament_flush_volumetric_speed` (Flush volumetric speed) | Flush volumetric speed |
| `filament_ironing_flow` (Ironing flow) | Ironing flow |
| `filament_ironing_inset` (Ironing inset) | Ironing inset |
| `filament_ironing_spacing` (Ironing line spacing) | Ironing line spacing |
| `filament_ironing_speed` (Ironing speed) | Ironing speed |
| `filament_is_mixed` (Is mixed filament) | Is mixed filament |
| `filament_loading_speed` (Loading speed) | Loading speed |
| `filament_loading_speed_start` (Loading speed at the start) | Loading speed at the start |
| `filament_map` (Filament map to extruder) | Filament map to extruder |
| `filament_map_2` (Filament map plus for multi nozzle) | Filament map plus for multi nozzle |
| `filament_map_mode` (filament mapping mode) | filament mapping mode |
| `filament_max_external_volumetric_speed` (Max external volumetric speed) | Max external volumetric speed |
| `filament_max_temperature_drop_when_ec` |  |
| `filament_minimal_purge_on_wipe_tower` (Minimal purge on wipe tower) | Minimal purge on wipe tower |
| `filament_mixed_components` (Mixed filament components) | Mixed filament components |
| `filament_mixed_gradient` (Mixed filament gradient) | Mixed filament gradient |
| `filament_mixed_gradient_curve` (Mixed filament gradient curve) | Mixed filament gradient curve |
| `filament_mixed_gradient_per_part` (Mixed filament per-part gradient) | Mixed filament per-part gradient |
| `filament_mixed_gradient_range` (Mixed filament gradient range) | Mixed filament gradient range |
| `filament_mixed_sublayer_ratios` (Mixed filament sublayer ratios) | Mixed filament sublayer ratios |
| `filament_multi_colour` |  |
| `filament_multitool_ramming` (Enable ramming for multi-tool setups) | Enable ramming for multi-tool setups |
| `filament_multitool_ramming_flow` (Multi-tool ramming flow) | Multi-tool ramming flow |
| `filament_multitool_ramming_volume` (Multi-tool ramming volume) | Multi-tool ramming volume |
| `filament_nozzle_map` |  |
| `filament_pre_cooling_temperature` (Extruder change) | Extruder change |
| `filament_pre_cooling_temperature_nc` (Hotend change) | Hotend change |
| `filament_preheat_temperature_delta` (Preheat temperature delta) | Preheat temperature delta |
| `filament_prime_volume` (Filament change) | Filament change |
| `filament_prime_volume_nc` (Hotend change) | Hotend change |
| `filament_printable` (Filament printable) | Filament printable |
| `filament_ramming_parameters` (Ramming parameters) | Ramming parameters |
| `filament_ramming_travel_time` (Extruder change) | Extruder change |
| `filament_ramming_travel_time_nc` (Hotend change) | Hotend change |
| `filament_ramming_volumetric_speed` (Extruder change) | Extruder change |
| `filament_ramming_volumetric_speed_nc` (Hotend change) | Hotend change |
| `filament_retract_length_nc` (length when change hotend) | length when change hotend |
| `filament_self_index` (Filament self index) | Filament self index |
| `filament_stamping_distance` (Stamping distance measured from the center of the cooling tube) | Stamping distance measured from the center of the cooling tube |
| `filament_stamping_loading_speed` (Stamping loading speed) | Stamping loading speed |
| `filament_toolchange_delay` (Delay after unloading) | Delay after unloading |
| `filament_tower_interface_pre_extrusion_dist` (Interface layer pre-extrusion distance) | Interface layer pre-extrusion distance |
| `filament_tower_interface_pre_extrusion_length` (Interface layer pre-extrusion length) | Interface layer pre-extrusion length |
| `filament_tower_interface_print_temp` (Interface layer print temperature) | Interface layer print temperature |
| `filament_tower_interface_purge_volume` (Interface layer purge length) | Interface layer purge length |
| `filament_tower_ironing_area` (Tower ironing area) | Tower ironing area |
| `filament_unloading_speed` (Unloading speed) | Unloading speed |
| `filament_unloading_speed_start` (Unloading speed at the start) | Unloading speed at the start |
| `filament_volume_map` |  |
| `file_start_gcode` (File header G-code) | File header G-code |
| `filename_format` (Filename format) | the name of the G-code file |
| `fill_multiline` (Fill Multiline) | Fill Multiline |
| `first_layer_flow_ratio` (First layer flow ratio) | First layer flow ratio |
| `first_layer_print_sequence` (First layer print sequence) | First layer print sequence |
| `first_layer_sequence_choice` (First layer filament sequence) | First layer filament sequence |
| `first_x_layer_fan_speed` (Fan speed) | Fan speed |
| `flush_into_infill` (Flush into objects' infill) | Flush into objects' infill |
| `flush_into_support` (Flush into objects' support) | Flush into objects' support |
| `flush_multiplier_fast` (Flush multiplier (Fast mode)) | Flush multiplier (Fast mode) |
| `fuzzy_skin_layers_between_ripple_offset` (Layers between ripple offset) | Layers between ripple offset |
| `fuzzy_skin_mode` (Fuzzy skin generator mode) | Fuzzy skin generator mode |
| `fuzzy_skin_noise_type` (Fuzzy skin noise type) | Fuzzy skin noise type |
| `fuzzy_skin_octaves` (Fuzzy Skin Noise Octaves) | Fuzzy Skin Noise Octaves |
| `fuzzy_skin_persistence` (Fuzzy skin noise persistence) | Fuzzy skin noise persistence |
| `fuzzy_skin_ripple_offset` (Ripple offset) | Ripple offset |
| `fuzzy_skin_ripples_per_layer` (Number of ripples per layer) | Number of ripples per layer |
| `fuzzy_skin_scale` (Fuzzy skin feature size) | Fuzzy skin feature size |
| `gap_fill_flow_ratio` (Gap fill flow ratio) | Gap fill flow ratio |
| `gap_infill_speed` (Gap infill) | Gap infill |
| `gap_infill_volumetric_flow` (Gap infill) | Gap infill |
| `gcode_add_line_number` (Add line number) | line numbers in the G-code |
| `gcode_comments` (Verbose G-code) | comments on each G-code line |
| `gcode_skip_config_block` (Skip G-code config block) | Skip G-code config block |
| `grab_length` (Grab length) | Grab length |
| `group_algo_with_time` |  |
| `gyroid_optimized` (Z-buckling bias optimization (experimental)) | Z-buckling bias optimization (experimental) |
| `handle_hotend_as_extruder` |  |
| `has_filament_switcher` (Has filament switcher) | Has filament switcher |
| `has_scarf_joint_seam` |  |
| `high_current_on_filament_swap` (High extruder current on filament swap) | High extruder current on filament swap |
| `high_precision_gcode` (High precision G-code (experimental)) | High precision G-code (experimental) |
| `hole_to_polyhole_max_edges` (Maximum Polyhole edge count) | Maximum Polyhole edge count |
| `hole_to_polyhole_twisted` (Polyhole twist) | polyholes that turn on each layer |
| `hotend_cooling_rate` |  |
| `hotend_heating_rate` |  |
| `imex_carriage_margin` (Safety Margin) | IDEX printers |
| `imex_firmware_managed_zones` (Firmware-managed zones) | IDEX printers |
| `imex_gantry_count` (Gantry Count) | IDEX printers |
| `imex_head_filament_map` (IDEX/IQEX head filament map) | IDEX printers |
| `imex_mode_active_tools` (IDEX/IQEX Mode Active Tools) | IDEX printers |
| `imex_mode_gcodes` (IDEX/IQEX Mode G-codes) | IDEX printers |
| `imex_mode_names` (IDEX/IQEX Mode Names) | IDEX printers |
| `imex_nozzle_clearance_x` (Nozzle Clearance X) | IDEX printers |
| `imex_nozzle_clearance_y` (Nozzle Clearance Y) | IDEX printers |
| `imex_parallel_mode` (IDEX/IQEX Print Mode) | IDEX printers |
| `imex_tool_layout` (Tool 0 Position) | IDEX printers |
| `imex_tools_per_gantry` (Tools per Gantry) | IDEX printers |
| `independent_support_layer_height` (Independent support layer height) | Independent support layer height |
| `infill_combination_max_layer_height` (Infill combination - Max layer height) | Infill combination - Max layer height |
| `infill_complete_top` (Fill pattern tops) | Fill pattern tops |
| `infill_jerk` (Infill) | Infill |
| `infill_lock_depth` (Infill lock depth) | Infill lock depth |
| `infill_overhang_angle` (Infill overhang angle) | Infill overhang angle |
| `infill_shift_step` (Infill shift step) | Infill shift step |
| `initial_layer_fan_speed` (First layer fan speed) | First layer fan speed |
| `initial_layer_infill_volumetric_flow` (First layer infill) | First layer infill |
| `initial_layer_jerk` (First layer) | First layer |
| `initial_layer_travel_acceleration` (First layer travel) | First layer travel |
| `initial_layer_travel_jerk` (First layer travel) | First layer travel |
| `initial_layer_volumetric_flow` (First layer) | First layer |
| `inner_wall_filament_id` (Inner walls) | Inner walls |
| `inner_wall_flow_ratio` (Inner wall flow ratio) | Inner wall flow ratio |
| `inner_wall_jerk` (Inner wall) | Inner wall |
| `inner_wall_line_width` (Inner wall) | Inner wall |
| `inner_wall_volumetric_flow` (Inner wall) | Inner wall |
| `input_shaping_damp_x` | write the input shaper of the firmware |
| `input_shaping_damp_y` | write the input shaper of the firmware |
| `input_shaping_emit` (Emit input shaping) | write the input shaper of the firmware |
| `input_shaping_freq_x` | write the input shaper of the firmware |
| `input_shaping_freq_y` | write the input shaper of the firmware |
| `input_shaping_type` (Input shaper type) | write the input shaper of the firmware |
| `internal_bridge_angle` (Internal bridge infill direction) | Internal bridge infill direction |
| `internal_bridge_density` (Internal bridge density) | Internal bridge density |
| `internal_bridge_fan_speed` (Internal bridges fan speed) | Internal bridges fan speed |
| `internal_bridge_flow` (Internal bridge flow ratio) | Internal bridge flow ratio |
| `internal_bridge_speed` (Internal) | Internal |
| `internal_bridge_volumetric_flow` (Internal) | Internal |
| `internal_solid_filament_id` (Internal solid infill) | Internal solid infill |
| `internal_solid_infill_flow_ratio` (Internal solid infill flow ratio) | Internal solid infill flow ratio |
| `internal_solid_infill_line_width` (Internal solid infill) | Internal solid infill |
| `internal_solid_infill_volumetric_flow` (Internal solid infill) | Internal solid infill |
| `ironing_angle` (Ironing angle offset) | Ironing angle offset |
| `ironing_angle_fixed` (Fixed ironing angle) | Fixed ironing angle |
| `ironing_expansion` (Ironing expansion) | Ironing expansion |
| `ironing_fan_speed` (Ironing fan speed) | Ironing fan speed |
| `ironing_pattern` (Ironing Pattern) | Ironing Pattern |
| `is_imex` (IDEX/IQEX Printer) | IDEX printers |
| `is_infill_first` (Print infill first) | Print infill first |
| `lateral_lattice_angle_1` (Lateral lattice angle 1) | Lateral lattice angle 1 |
| `lateral_lattice_angle_2` (Lateral lattice angle 2) | Lateral lattice angle 2 |
| `layer_change_gcode` (Layer change G-code) | G-code at each layer change (zslice writes the layer G-code of the Bambu Lab templates only) |
| `leading_brim_length` (Leading brim length) | Leading brim length |
| `long_retractions_when_cut` (Long retraction when cut (beta)) | Long retraction when cut (beta) |
| `long_retractions_when_ec` (Long retraction when extruder change) | Long retraction when extruder change |
| `machine_bed_mass_Y` |  |
| `machine_hotend_change_time` (Hotend change time) | Hotend change time |
| `machine_max_acceleration_retracting` | the acceleration limit of a retraction |
| `machine_max_force_Y` |  |
| `machine_max_printed_mass` |  |
| `machine_min_extruding_rate` | the lowest speed of the firmware, for the time estimate |
| `machine_min_travel_rate` | the lowest speed of the firmware, for the time estimate |
| `machine_prepare_compensation_time` |  |
| `make_overhang_printable` (Make overhangs printable) | Make overhangs printable |
| `make_overhang_printable_angle` (Make overhangs printable - Maximum angle) | Make overhangs printable - Maximum angle |
| `make_overhang_printable_hole_size` (Make overhangs printable - Hole area) | Make overhangs printable - Hole area |
| `master_extruder_id` (Master extruder id) | Master extruder id |
| `max_bridge_length` (Max bridge length) | Max bridge length |
| `max_resonance_avoidance_speed` (Max) | Max |
| `max_volumetric_extrusion_rate_slope` (Extrusion rate smoothing) | Extrusion rate smoothing |
| `max_volumetric_extrusion_rate_slope_segment_length` (Smoothing segment length) | Smoothing segment length |
| `min_length_factor` (Minimum wall length) | Minimum wall length |
| `min_resonance_avoidance_speed` (Min) | Min |
| `min_skirt_length` (Skirt minimum extrusion length) | Skirt minimum extrusion length |
| `min_width_top_surface` (One wall threshold) | One wall threshold |
| `nozzle_flush_dataset` |  |
| `nozzle_height` (Nozzle height) | the height of the nozzle under the head, for one-at-a-time print order |
| `nozzle_volume` (Nozzle volume) | the volume of the nozzle, for the flush of a filament change |
| `nozzle_volume_type` (Nozzle Volume Type) | Nozzle Volume Type |
| `only_one_wall_first_layer` (Only one wall on first layer) | Only one wall on first layer |
| `only_one_wall_top` (Only one wall on top surfaces) | Only one wall on top surfaces |
| `ooze_prevention` (Enable) | Enable |
| `other_layers_print_sequence` (Other layers print sequence) | Other layers print sequence |
| `other_layers_print_sequence_nums` (The number of other layers print sequence) | The number of other layers print sequence |
| `other_layers_sequence_choice` (Other layers filament sequence) | Other layers filament sequence |
| `outer_wall_filament_id` (Outer walls) | Outer walls |
| `outer_wall_flow_ratio` (Outer wall flow ratio) | Outer wall flow ratio |
| `outer_wall_jerk` (Outer wall) | Outer wall |
| `outer_wall_line_width` (Outer wall) | Outer wall |
| `outer_wall_volumetric_flow` (Outer wall) | Outer wall |
| `overhang_flow_ratio` (Overhang flow ratio) | Overhang flow ratio |
| `overhang_reverse` (Reverse on even) | Reverse on even |
| `overhang_reverse_internal_only` (Reverse only internal perimeters) | Reverse only internal perimeters |
| `overhang_reverse_threshold` (Reverse threshold) | Reverse threshold |
| `parking_pos_retraction` (Filament parking position) | Filament parking position |
| `part_cooling_fan_min_pwm` (Minimum non-zero part cooling fan speed) | Minimum non-zero part cooling fan speed |
| `physical_extruder_map` (Map the logical extruder to physical extruder) | Map the logical extruder to physical extruder |
| `precise_outer_wall` (Precise wall) | Precise wall |
| `preheat_steps` (Preheat steps) | Preheat steps |
| `preheat_time` (Preheat time) | Preheat time |
| `prime_tower_brim_width` (Brim width) | Brim width |
| `prime_tower_enable_framework` (Internal ribs) | Internal ribs |
| `prime_tower_flat_ironing` |  |
| `prime_tower_infill_gap` (Infill gap) | Infill gap |
| `prime_tower_skip_points` (Skip points) | Skip points |
| `prime_volume` (Prime volume) | Prime volume |
| `prime_volume_mode` (Prime volume mode) | Prime volume mode |
| `print_extruder_id` (Print extruder id) | Print extruder id |
| `print_extruder_variant` (Print's extruder variant) | Print's extruder variant |
| `print_flow_ratio` (Flow ratio) | Flow ratio |
| `print_order` (Intra-layer order) | Intra-layer order |
| `print_sequence` (Print sequence) | one part at a time |
| `printer_extruder_id` (Printer extruder id) | Printer extruder id |
| `printer_extruder_variant` (Printer's extruder variant) | Printer's extruder variant |
| `printing_by_object_gcode` (Between Object G-code) | G-code between the parts of one-at-a-time print order |
| `process_change_extrusion_role_gcode` (Change extrusion role G-code (process)) | Change extrusion role G-code (process) |
| `purge_in_prime_tower` (Purge in prime tower) | Purge in prime tower |
| `raft_contact_distance` (Raft contact Z distance) | Raft contact Z distance |
| `raft_expansion` (Raft expansion) | Raft expansion |
| `raft_first_layer_density` (First layer density) | First layer density |
| `raft_first_layer_expansion` (First layer expansion) | First layer expansion |
| `raft_layers` (Raft layers) | Raft layers |
| `reduce_fan_stop_start_freq` (Keep fan always on) | Keep fan always on |
| `relative_bridge_angle` (Relative bridge angle) | Relative bridge angle |
| `resonance_avoidance` (Resonance avoidance) | Resonance avoidance |
| `retract_after_outer_wall` (Retract after outer wall) | Retract after outer wall |
| `retract_after_wipe` (Retract amount after wipe) | Retract amount after wipe |
| `retract_before_wipe` (Retract amount before wipe) | Retract amount before wipe |
| `retract_lift_above` (Z-hop lower boundary) | Z-hop lower boundary |
| `retract_lift_below` (Z-hop upper boundary) | Z-hop upper boundary |
| `retract_restart_extra` (Extra length on restart) | Extra length on restart |
| `retract_restart_extra_toolchange` (Extra length on restart (Toolchange)) | Extra length on restart (Toolchange) |
| `retraction_distances_when_cut` (Retraction distance when cut) | Retraction distance when cut |
| `retraction_distances_when_ec` (Retraction distance when extruder change) | Retraction distance when extruder change |
| `role_based_wipe_speed` (Role based wipe speed) | Role based wipe speed |
| `scarf_angle_threshold` (Conditional angle threshold) | Conditional angle threshold |
| `scarf_joint_flow_ratio` (Scarf joint flow ratio) | Scarf joint flow ratio |
| `scarf_joint_speed` (Scarf joint speed) | Scarf joint speed |
| `scarf_overhang_threshold` (Conditional overhang threshold) | Conditional overhang threshold |
| `seam_gap` (Seam gap) | Seam gap |
| `seam_slope_conditional` (Conditional scarf joint) | Conditional scarf joint |
| `seam_slope_entire_loop` (Scarf around entire wall) | Scarf around entire wall |
| `seam_slope_inner_walls` (Scarf joint for inner walls) | Scarf joint for inner walls |
| `seam_slope_min_length` (Scarf length) | Scarf length |
| `seam_slope_start_height` (Scarf start height) | Scarf start height |
| `seam_slope_steps` (Scarf steps) | Scarf steps |
| `seam_slope_type` (Scarf joint seam (beta)) | Scarf joint seam (beta) |
| `separated_infills` (Separated infills) | Separated infills |
| `set_other_flow_ratios` (Set other flow ratios) | Set other flow ratios |
| `single_extruder_multi_material_priming` (Prime all printing extruders) | Prime all printing extruders |
| `single_loop_draft_shield` (Single loop after first layer) | Single loop after first layer |
| `skeleton_infill_density` (Skeleton infill density) | Skeleton infill density |
| `skeleton_infill_line_width` (Skeleton line width) | Skeleton line width |
| `skin_infill_density` (Skin infill density) | Skin infill density |
| `skin_infill_depth` (Skin infill depth) | Skin infill depth |
| `skin_infill_line_width` (Skin line width) | Skin line width |
| `skirt_speed` (Skirt speed) | Skirt speed |
| `skirt_start_angle` (Skirt start point) | Skirt start point |
| `skirt_type` (Skirt type) | Skirt type |
| `slicing_mode` (Slicing Mode) | the fill rule of the outlines (regular, even-odd, close holes) |
| `slowdown_for_curled_perimeters` (Slow down for curled perimeters) | Slow down for curled perimeters |
| `small_area_infill_flow_compensation` (Small area flow compensation (beta)) | Small area flow compensation (beta) |
| `small_area_infill_flow_compensation_model` (Flow Compensation Model) | Flow Compensation Model |
| `small_perimeter_speed` (Small perimeters) | Small perimeters |
| `small_perimeter_threshold` (Small perimeters threshold) | Small perimeters threshold |
| `small_support_perimeter_speed` (Small support perimeters) | Small support perimeters |
| `small_support_perimeter_threshold` (Small support perimeters threshold) | Small support perimeters threshold |
| `solid_infill_rotate_template` (Solid infill rotation template) | Solid infill rotation template |
| `sparse_infill_filament_id` (Infill) | Infill |
| `sparse_infill_flow_ratio` (Sparse infill flow ratio) | Sparse infill flow ratio |
| `sparse_infill_line_width` (Sparse infill) | Sparse infill |
| `sparse_infill_rotate_template` (Sparse infill rotation template) | Sparse infill rotation template |
| `sparse_infill_smooth_factor` (Sparse infill smooth factor) | Sparse infill smooth factor |
| `sparse_infill_strategy` (Sparse infill strategy) | Sparse infill strategy |
| `sparse_infill_volumetric_flow` (Sparse infill) | Sparse infill |
| `spiral_finishing_flow_ratio` (Spiral finishing flow ratio) | Spiral finishing flow ratio |
| `spiral_mode_max_xy_smoothing` (Max XY Smoothing) | Max XY Smoothing |
| `spiral_mode_smooth` (Smooth Spiral) | Smooth Spiral |
| `spiral_starting_flow_ratio` (Spiral starting flow ratio) | Spiral starting flow ratio |
| `staggered_inner_seams` (Staggered inner seams) | Staggered inner seams |
| `start_end_points` (Start end points) | Start end points |
| `support_base_pattern` (Base pattern) | Base pattern |
| `support_bottom_interface_spacing` (Bottom interface spacing) | Bottom interface spacing |
| `support_cooling_filter` |  |
| `support_critical_regions_only` (Support critical regions only) | Support critical regions only |
| `support_expansion` (Normal support expansion) | Normal support expansion |
| `support_fast_purge_mode` (Support fast purge mode) | Support fast purge mode |
| `support_flow_ratio` (Support flow ratio) | Support flow ratio |
| `support_interface_bottom_layers` (Bottom interface layers) | Bottom interface layers |
| `support_interface_flow_ratio` (Support interface flow ratio) | Support interface flow ratio |
| `support_interface_loop_pattern` (Loop pattern interface) | Loop pattern interface |
| `support_interface_not_for_body` (Avoid interface filament for base) | Avoid interface filament for base |
| `support_interface_volumetric_flow` (Support interface) | Support interface |
| `support_ironing` (Ironing Support Interface) | Ironing Support Interface |
| `support_ironing_flow` (Support Ironing flow) | Support Ironing flow |
| `support_ironing_pattern` (Support Ironing Pattern) | Support Ironing Pattern |
| `support_ironing_spacing` (Support Ironing line spacing) | Support Ironing line spacing |
| `support_line_width` (Support) | Support |
| `support_material_interface_fan_speed` (Support interface fan speed) | Support interface fan speed |
| `support_object_first_layer_gap` (Support/object first layer gap) | Support/object first layer gap |
| `support_object_skip_flush` |  |
| `support_threshold_overlap` (Threshold overlap) | Threshold overlap |
| `support_volumetric_flow` (Support) | Support |
| `symmetric_infill_y_axis` (Symmetric infill Y axis) | Symmetric infill Y axis |
| `template_custom_gcode` (Custom G-code) | a custom G-code at a layer |
| `thick_bridges` (Thick external bridges) | Thick external bridges |
| `thick_internal_bridges` (Thick internal bridges) | Thick internal bridges |
| `time_lapse_gcode` (Timelapse G-code) | G-code for a time-lapse at each layer |
| `timelapse_type` (Timelapse) | Timelapse |
| `tool_change_on_wipe_tower` (Tool change on wipe tower) | Tool change on wipe tower |
| `toolchange_cyclic_first_layer` (Apply cyclic order to first layer) | Apply cyclic order to first layer |
| `toolchange_cyclic_order` (Cyclic order) | Cyclic order |
| `toolchange_ordering` (Toolchange ordering) | Toolchange ordering |
| `top_color_penetration_layers` (Top paint penetration layers) | Top paint penetration layers |
| `top_layer_direction` (Top layer direction) | Top layer direction |
| `top_solid_infill_flow_ratio` (Top surface flow ratio) | Top surface flow ratio |
| `top_surface_density` (Top surface density) | Top surface density |
| `top_surface_expansion` (Top surface expansion) | Top surface expansion |
| `top_surface_expansion_direction` (Top expansion direction) | Top expansion direction |
| `top_surface_expansion_margin` (Top expansion wall margin) | Top expansion wall margin |
| `top_surface_filament_id` (Top surface) | Top surface |
| `top_surface_fill_order` (Top surface fill order) | Top surface fill order |
| `top_surface_jerk` (Top surface) | Top surface |
| `top_surface_line_width` (Top surface) | Top surface |
| `top_surface_volumetric_flow` (Top surface) | Top surface |
| `travel_jerk` (Travel) | Travel |
| `travel_slope` (Traveling angle) | Traveling angle |
| `tree_support_angle_slow` (Preferred Branch Angle) | Preferred Branch Angle |
| `tree_support_brim_width` (Tree support brim width) | Tree support brim width |
| `tree_support_top_rate` (Branch Density) | Branch Density |
| `tree_support_wall_count` (Support wall loops) | Support wall loops |
| `tree_support_with_infill` (Tree support with infill) | Tree support with infill |
| `unsupported_wall_last` (Print unsupported walls last) | Print unsupported walls last |
| `use_firmware_retraction` (Use firmware retraction) | G10 and G11 for the retraction |
| `volumetric_speed_coefficients` (Max volumetric speed multinomial coefficients) | Max volumetric speed multinomial coefficients |
| `wait_for_temp_on_wipe_tower` (Wait for temperature on wipe tower) | Wait for temperature on wipe tower |
| `wall_direction` (Wall loop direction) | Wall loop direction |
| `wall_maximum_deviation` (Maximum wall deviation) | Maximum wall deviation |
| `wall_maximum_resolution` (Maximum wall resolution) | Maximum wall resolution |
| `wipe_before_external_loop` (Wipe before external loop) | Wipe before external loop |
| `wipe_inward` (Wipe inward) | Wipe inward |
| `wipe_inward_distance` (Wipe inward distance) | Wipe inward distance |
| `wipe_on_loops` (Wipe on loops) | Wipe on loops |
| `wipe_speed` (Wipe speed) | Wipe speed |
| `wipe_tower_bridging` (Maximal bridging distance) | Maximal bridging distance |
| `wipe_tower_cone_angle` (Stabilization cone apex angle) | Stabilization cone apex angle |
| `wipe_tower_extra_flow` (Extra flow for purging) | Extra flow for purging |
| `wipe_tower_extra_rib_length` (Extra rib length) | Extra rib length |
| `wipe_tower_extra_spacing` (Wipe tower purge lines spacing) | Wipe tower purge lines spacing |
| `wipe_tower_filament` (Wipe tower) | Wipe tower |
| `wipe_tower_fillet_wall` (Fillet wall) | Fillet wall |
| `wipe_tower_max_purge_speed` (Maximum wipe tower print speed) | Maximum wipe tower print speed |
| `wipe_tower_no_sparse_layers` (No sparse layers (beta)) | No sparse layers (beta) |
| `wipe_tower_rib_width` (Rib width) | Rib width |
| `wipe_tower_rotation_angle` (Wipe tower rotation angle) | Wipe tower rotation angle |
| `wipe_tower_sparse_layers_combination` (Combine sparse layers) | Combine sparse layers |
| `wipe_tower_type` (Wipe tower type) | Wipe tower type |
| `wipe_tower_wall_type` (Wall type) | Wall type |
| `wiping_volumes_extruders` (Purging volumes - load/unload volumes) | Purging volumes - load/unload volumes |
| `z_offset` (Z offset) | a Z offset of the whole print |

### Not for zslice

| OrcaSlicer setting | zslice |
|---|---|
| `bbl_calib_mark_logo` (Show auto-calibration marks) | a calibration mark of Bambu Lab printers |
| `bbl_use_printhost` (Use 3rd-party print host) | a printer connection of the OrcaSlicer app (zslice has its own printer links) |
| `belt_frame_tilt_angle` (Machine-frame tilt angle) | belt printers |
| `belt_frame_tilt_decouple` (Decouple machine-frame tilt) | belt printers |
| `belt_printer` (Enable belt printing) | belt printers |
| `belt_printer_infinite_y` (Infinite Y axis) | belt printers |
| `belt_purge_tower_object` (Belt purge tower object) | belt printers |
| `belt_purge_tower_width` (Belt purge tower width) | belt printers |
| `belt_slice_rotation` (Belt tilt axis) | belt printers |
| `belt_slice_rotation_angle` (Belt tilt angle) | belt printers |
| `belt_support_floor_offset` (Support Floor Z offset) | belt printers |
| `build_plate_tilt_x` (Build plate tilt X) | printers with a tilted bed |
| `build_plate_tilt_y` (Build plate tilt Y) | printers with a tilted bed |
| `calib_flowrate_topinfill_special_order` | a calibration of the OrcaSlicer app |
| `compatible_machine_expression_group` | preset metadata of the OrcaSlicer app |
| `compatible_printers` (Select printers) | preset metadata of the OrcaSlicer app |
| `compatible_printers_condition` (Condition) | preset metadata of the OrcaSlicer app |
| `compatible_prints` (Select profiles) | preset metadata of the OrcaSlicer app |
| `compatible_prints_condition` (Condition) | preset metadata of the OrcaSlicer app |
| `compatible_process_expression_group` | preset metadata of the OrcaSlicer app |
| `default_filament_profile` (Default filament profile) | preset metadata of the OrcaSlicer app |
| `default_print_profile` (Default process profile) | preset metadata of the OrcaSlicer app |
| `different_settings_to_system` | preset metadata of the OrcaSlicer app |
| `enable_belt_purge_tower` (Enable belt purge tower) | belt printers |
| `enable_wrapping_detection` (Enable clumping detection) | the clog detection of Bambu Lab printers |
| `filament_ids` | preset metadata of the OrcaSlicer app |
| `filament_notes` (Filament notes) | preset metadata of the OrcaSlicer app |
| `filament_settings_id` | preset metadata of the OrcaSlicer app |
| `flashforge_serial_number` (Serial Number) | a printer connection of the OrcaSlicer app |
| `head_wrap_detect_zone` (Head wrap detect zone) | the clog detection of Bambu Lab printers |
| `host_type` (Host Type) | a printer connection of the OrcaSlicer app |
| `imex_viz_theme` (Visualization Theme) | a color theme of the OrcaSlicer app |
| `inherits_group` | preset metadata of the OrcaSlicer app |
| `max_layer_height` (Max) | the limits of adaptive layers in the OrcaSlicer app |
| `min_layer_height` (Min) | the limits of adaptive layers in the OrcaSlicer app |
| `notes` (Configuration notes) | preset metadata of the OrcaSlicer app |
| `parallel_printheads_bed_exclude_areas` (Parallel printheads bed exclude areas) | printers with many heads that print copies at once |
| `parallel_printheads_count` (Parallel printheads count) | printers with many heads that print copies at once |
| `pellet_flow_coefficient` (Pellet flow coefficient) | pellet printers |
| `pellet_modded_printer` (Pellet Modded Printer) | pellet printers |
| `plugins` (Plugins Used) | plugins of the OrcaSlicer app |
| `post_process` (Post-processing Scripts) | scripts that change the G-code after the slice |
| `preferred_orientation` (Preferred orientation) | the angle of the bed in the 3D view of the app |
| `preset_name` | preset metadata of the OrcaSlicer app |
| `preset_names` (Printer preset names) | preset metadata of the OrcaSlicer app |
| `print_compatible_printers` | preset metadata of the OrcaSlicer app |
| `print_host` (Hostname, IP or URL) | a printer connection of the OrcaSlicer app (zslice has its own printer links) |
| `print_host_webui` (Device UI) | a printer connection of the OrcaSlicer app |
| `print_settings_id` | preset metadata of the OrcaSlicer app |
| `printer_agent` (Printer Agent) | a printer connection of the OrcaSlicer app |
| `printer_notes` (Printer notes) | preset metadata of the OrcaSlicer app |
| `printer_settings_id` | preset metadata of the OrcaSlicer app |
| `printer_technology` (Printer technology) | FDM or SLA: zslice is for FDM printers |
| `printhost_apikey` (API Key / Password) | a printer connection of the OrcaSlicer app |
| `printhost_authorization_type` (Authorization Type) | a printer connection of the OrcaSlicer app |
| `printhost_cafile` (HTTPS CA File) | a printer connection of the OrcaSlicer app |
| `printhost_password` (Password) | a printer connection of the OrcaSlicer app |
| `printhost_port` (Printer) | a printer connection of the OrcaSlicer app |
| `printhost_ssl_ignore_revoke` (Ignore HTTPS certificate revocation checks) | a printer connection of the OrcaSlicer app |
| `printhost_user` (User) | a printer connection of the OrcaSlicer app |
| `scan_first_layer` (Scan first layer) | the first layer scan of Bambu Lab printers |
| `slicing_pipeline_plugin` (Slicing Pipeline Plugin) | plugins of the OrcaSlicer app |
| `support_air_filtration` (Support air filtration) | the air filter of Bambu Lab printers |
| `support_parallel_printheads` (Support parallel printheads) | printers with many heads that print copies at once |
| `upward_compatible_machine` (upward compatible machine) | preset metadata of the OrcaSlicer app |
| `use_3mf` (Use 3MF instead of G-code) | a printer connection of the OrcaSlicer app |
| `wrapping_detection_gcode` (Clumping detection G-code) | the clog detection of Bambu Lab printers |
| `wrapping_detection_layers` (Clumping detection layers) | the clog detection of Bambu Lab printers |
| `wrapping_exclude_area` (Probing exclude area of clumping) | the clog detection of Bambu Lab printers |

### Other blocks

| OrcaSlicer key | Status | Note |
|---|---|---|
| `export_3mf` | Not for zslice | an option of the orca-slicer command line |
| `export_amf` | Not for zslice | an option of the orca-slicer command line |
| `export_gcode` | Not for zslice | an option of the orca-slicer command line |
| `export_obj` | Not for zslice | an option of the orca-slicer command line |
| `export_settings` | Not for zslice | an option of the orca-slicer command line |
| `export_sla` | Not for zslice | an option of the orca-slicer command line |
| `export_slicedata` | Not for zslice | an option of the orca-slicer command line |
| `export_stl` | Not for zslice | an option of the orca-slicer command line |
| `export_stls` | Not for zslice | an option of the orca-slicer command line |
| `export_svg` | Not for zslice | an option of the orca-slicer command line |
| `gcodeviewer` | Not for zslice | an option of the orca-slicer command line |
| `help` | Not for zslice | an option of the orca-slicer command line |
| `help_fff` | Not for zslice | an option of the orca-slicer command line |
| `help_sla` | Not for zslice | an option of the orca-slicer command line |
| `info` | Not for zslice | an option of the orca-slicer command line |
| `inspect_mesh` | Not for zslice | an option of the orca-slicer command line |
| `inspect_paint` | Not for zslice | an option of the orca-slicer command line |
| `load_defaultfila` | Not for zslice | an option of the orca-slicer command line |
| `load_slicedata` | Not for zslice | an option of the orca-slicer command line |
| `min_save` | Not for zslice | an option of the orca-slicer command line |
| `mstpp` | Not for zslice | an option of the orca-slicer command line |
| `mtcpp` | Not for zslice | an option of the orca-slicer command line |
| `no_check` | Not for zslice | an option of the orca-slicer command line |
| `normative_check` | Not for zslice | an option of the orca-slicer command line |
| `pipe` | Not for zslice | an option of the orca-slicer command line |
| `slice` | Not for zslice | an option of the orca-slicer command line |
| `strict` | Not for zslice | an option of the orca-slicer command line |
| `uptodate` | Not for zslice | an option of the orca-slicer command line |
| `align_to_y_axis` | Not for zslice | an option of the orca-slicer command line |
| `allow_mix_temp` | Not for zslice | an option of the orca-slicer command line |
| `allow_multicolor_oneplate` | Not for zslice | an option of the orca-slicer command line |
| `allow_newer_file` | Not for zslice | an option of the orca-slicer command line |
| `allow_rotations` | Not for zslice | an option of the orca-slicer command line |
| `autosave` | Not for zslice | an option of the orca-slicer command line |
| `avoid_extrusion_cali_region` | Not for zslice | an option of the orca-slicer command line |
| `clone_objects` | Not for zslice | an option of the orca-slicer command line |
| `config_compatibility` | Not for zslice | an option of the orca-slicer command line |
| `datadir` | Not for zslice | an option of the orca-slicer command line |
| `debug` | Not for zslice | an option of the orca-slicer command line |
| `downward_check` | Not for zslice | an option of the orca-slicer command line |
| `downward_settings` | Not for zslice | an option of the orca-slicer command line |
| `enable_timelapse` | Not for zslice | an option of the orca-slicer command line |
| `export_statistics` | Not for zslice | an option of the orca-slicer command line |
| `ignore_nonexistent_config` | Not for zslice | an option of the orca-slicer command line |
| `load` | Not for zslice | an option of the orca-slicer command line |
| `load_assemble_list` | Not for zslice | an option of the orca-slicer command line |
| `load_custom_gcodes` | Not for zslice | an option of the orca-slicer command line |
| `load_filament_ids` | Not for zslice | an option of the orca-slicer command line |
| `load_filaments` | Not for zslice | an option of the orca-slicer command line |
| `load_settings` | Not for zslice | an option of the orca-slicer command line |
| `logfile` | Not for zslice | an option of the orca-slicer command line |
| `makerlab_name` | Not for zslice | an option of the orca-slicer command line |
| `makerlab_version` | Not for zslice | an option of the orca-slicer command line |
| `metadata_name` | Not for zslice | an option of the orca-slicer command line |
| `metadata_value` | Not for zslice | an option of the orca-slicer command line |
| `output` | Not for zslice | an option of the orca-slicer command line |
| `outputdir` | Not for zslice | an option of the orca-slicer command line |
| `single_instance` | Not for zslice | an option of the orca-slicer command line |
| `skip_modified_gcodes` | Not for zslice | an option of the orca-slicer command line |
| `skip_objects` | Not for zslice | an option of the orca-slicer command line |
| `sw_renderer` | Not for zslice | an option of the orca-slicer command line |
| `uptodate_filaments` | Not for zslice | an option of the orca-slicer command line |
| `uptodate_settings` | Not for zslice | an option of the orca-slicer command line |
| `align_xy` | Not for zslice | an option of the orca-slicer command line |
| `arrange` | Not for zslice | an option of the orca-slicer command line |
| `assemble` | Not for zslice | an option of the orca-slicer command line |
| `center` | Not for zslice | an option of the orca-slicer command line |
| `convert_unit` | Not for zslice | an option of the orca-slicer command line |
| `copy` | Not for zslice | an option of the orca-slicer command line |
| `cut` | Not for zslice | an option of the orca-slicer command line |
| `cut_grid` | Not for zslice | an option of the orca-slicer command line |
| `cut_x` | Not for zslice | an option of the orca-slicer command line |
| `cut_y` | Not for zslice | an option of the orca-slicer command line |
| `duplicate_grid` | Not for zslice | an option of the orca-slicer command line |
| `ensure_on_bed` | Not for zslice | an option of the orca-slicer command line |
| `ground_face_normal` | Not for zslice | an option of the orca-slicer command line |
| `ground_face_point` | Not for zslice | an option of the orca-slicer command line |
| `ground_largest_face` | Not for zslice | an option of the orca-slicer command line |
| `orient` | Not for zslice | an option of the orca-slicer command line |
| `repair` | Not for zslice | an option of the orca-slicer command line |
| `repetitions` | Not for zslice | an option of the orca-slicer command line |
| `rotate` | Not for zslice | an option of the orca-slicer command line |
| `rotate_x` | Not for zslice | an option of the orca-slicer command line |
| `rotate_y` | Not for zslice | an option of the orca-slicer command line |
| `scale` | Not for zslice | an option of the orca-slicer command line |
| `scale_to_fit` | Not for zslice | an option of the orca-slicer command line |
| `split` | Not for zslice | an option of the orca-slicer command line |
| `extrusion_role` | Missing | a G-code variable |
| `last_extrusion_role` | Missing | a G-code variable |
| `layer_num` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `layer_z` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `max_layer_z` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `first_layer_print_convex_hull` | Missing | a G-code variable |
| `first_layer_print_max` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `first_layer_print_min` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `first_layer_print_size` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `print_bed_max` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `print_bed_min` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `print_bed_size` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `input_filename_base` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `num_instances` | Missing | a G-code variable |
| `num_objects` | Missing | a G-code variable |
| `filament_preset` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `physical_printer_preset` | Missing | a G-code variable |
| `print_preset` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `printer_preset` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `current_extruder` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `current_object_idx` | Missing | a G-code variable |
| `has_single_extruder_multi_material_priming` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `has_wipe_tower` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `initial_extruder` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `initial_filament_type` | Missing | a G-code variable |
| `initial_tool` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `is_extruder_used` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `num_extruders` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `extruded_volume` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `extruded_volume_total` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `extruded_weight` | Missing | a G-code variable |
| `extruded_weight_total` | Missing | a G-code variable |
| `normal_print_time` | Missing | a G-code variable |
| `num_printing_extruders` | Missing | a G-code variable |
| `print_time` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `print_time_day` | Missing | a G-code variable |
| `print_time_hour` | Missing | a G-code variable |
| `print_time_minute` | Missing | a G-code variable |
| `print_time_sec` | Missing | a G-code variable |
| `print_time_total_sec` | Missing | a G-code variable |
| `printing_filament_types` | Missing | a G-code variable |
| `silent_print_time` | Missing | a G-code variable |
| `total_cost` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `total_layer_count` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `total_toolchanges` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `total_weight` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `total_wipe_tower_cost` | Missing | a G-code variable |
| `total_wipe_tower_filament` | Missing | a G-code variable |
| `used_filament` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `used_filament_length` | Missing | a G-code variable |
| `zhop` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `e_position` | Missing | a G-code variable |
| `e_restart_extra` | Missing | a G-code variable |
| `e_retracted` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `position` | Missing | a G-code variable |
| `day` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `hour` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `minute` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `month` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `second` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `timestamp` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `year` | Covered | a G-code variable that zslice fills in (src/gcode_vars.zig) |
| `absolute_correction` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `area_fill` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `bottle_cost` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `bottle_volume` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `bottle_weight` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `default_sla_material_profile` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `default_sla_print_profile` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `display_height` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `display_mirror_x` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `display_mirror_y` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `display_orientation` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `display_pixels_x` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `display_pixels_y` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `display_width` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `elefant_foot_min_width` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `exposure_time` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `faded_layers` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `fast_tilt_time` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `gamma_correction` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `hollowing_closing_distance` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `hollowing_enable` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `hollowing_min_thickness` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `hollowing_quality` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `initial_exposure_time` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `initial_layer_height` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `material_colour` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `material_correction` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `material_correction_x` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `material_correction_y` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `material_correction_z` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `material_density` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `material_print_speed` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `material_type` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `material_vendor` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `max_exposure_time` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `max_initial_exposure_time` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `min_exposure_time` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `min_initial_exposure_time` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_around_object` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_around_object_everywhere` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_brim_size` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_enable` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_max_merge_distance` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_object_connector_penetration` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_object_connector_stride` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_object_connector_width` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_object_gap` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_wall_height` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_wall_slope` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `pad_wall_thickness` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `relative_correction` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `relative_correction_x` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `relative_correction_y` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `relative_correction_z` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `sla_material_settings_id` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `sla_print_settings_id` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `slow_tilt_time` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_base_diameter` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_base_height` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_base_safety_distance` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_buildplate_only` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_critical_angle` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_head_front_diameter` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_head_penetration` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_head_width` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_max_bridge_length` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_max_bridges_on_pillar` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_max_pillar_link_distance` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_object_elevation` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_pillar_connection_mode` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_pillar_diameter` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_pillar_widening_factor` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_points_density_relative` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_points_minimal_distance` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `support_small_pillar_diameter_percent` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
| `supports_enable` | Not for zslice | resin (SLA) printers: zslice slices for FDM printers |
