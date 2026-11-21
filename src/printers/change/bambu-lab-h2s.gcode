;===== machine: H2S filament_change =====
;===== date: 2026/01/28 =====

M993 A2 B2 C2 ; nozzle cam detection allow status save.
M993 A0 B0 C0 ; nozzle cam detection not allowed.

{if (filament_type[next_extruder] == "PLA") ||  (filament_type[next_extruder] == "PETG")
 ||  (filament_type[next_extruder] == "PLA-CF")  ||  (filament_type[next_extruder] == "PETG-CF")}
M1015.4 S1 K0 ;disable E air printing detect
{else}
M1015.4 S0 ; disable E air printing detect
{endif}

M620 S[next_extruder]A
M1002 gcode_claim_action : 4
M204 S9000

G1 Z{max_layer_z + 3.0} F1200

M400
M106 P1 S0
M106 P2 S0

{if toolchange_count == 2}
; get travel path for change filament
;M620.1 X[travel_point_1_x] Y[travel_point_1_y] F21000 P0
;M620.1 X[travel_point_2_x] Y[travel_point_2_y] F21000 P1
;M620.1 X[travel_point_3_x] Y[travel_point_3_y] F21000 P2
{endif}

M620.10 A0 F{flush_volumetric_speeds[current_extruder]/2.4053*60*0.8} L[flush_length] H{nozzle_diameter[current_extruder]} T{flush_temperatures[current_extruder]} P[old_filament_temp] S1
M620.10 A1 F{flush_volumetric_speeds[next_extruder]/2.4053*60*0.8} L[flush_length] H{nozzle_diameter[next_extruder]} T{flush_temperatures[next_extruder]} P[new_filament_temp] S1

{if long_retraction_when_cut}
M620.11 P1 I[current_extruder] E-{retraction_distance_when_cut} F{max((flush_volumetric_speeds[current_extruder]/2.4053*60), 200)}
{else}
M620.11 P0 I[current_extruder] E0
{endif}


{if filament_type[current_extruder] == "TPU" || filament_type[next_extruder] == "TPU"}
M620.11 H2 C331
{else}
M620.11 H0
{endif}

M620.15 C{new_filament_temp - filament_cooling_before_tower[next_extruder]}

T[next_extruder]


; VFLUSH_START

{if flush_length>41.5}
;VG1 E41.5 F{min(old_filament_e_feedrate,new_filament_e_feedrate)}
;VG1 E{flush_length-41.5} F{new_filament_e_feedrate}
{else}
;VG1 E{flush_length} F{min(old_filament_e_feedrate,new_filament_e_feedrate)}
{endif}

SYNC T{ceil(flush_length / 125) * 5}

; VFLUSH_END

M1002 set_filament_type:{filament_type[next_extruder]}

M400
M83
{if next_extruder < 255}

M620.10 R{retract_length_toolchange[filament_map[next_extruder]-1]}
M628 S0
;VM109 S[new_filament_temp]

M629
M400

;prime_tower_interface
{if is_prime_tower_interface && filament_tower_interface_purge_volume !=0}
G150.1
M620.13 W0 L{filament_tower_interface_purge_volume} T{filament_tower_interface_print_temp} R0.0
{endif}
;prime_tower_interface

M983.3 F{filament_max_volumetric_speed[next_extruder]/2.4} A0.4 R{retract_length_toolchange[filament_map[next_extruder]-1]}

M400
{if wipe_avoid_perimeter}
G1 Y320 F30000
G1 X{wipe_avoid_pos_x} F30000
{endif}
G1 Y295 F30000
G1 Y265 F18000
G1 Z{max_layer_z + 3.0} F3000
{if layer_z <= (initial_layer_print_height + 0.001)}
M204 S[initial_layer_acceleration]
{else}
M204 S[default_acceleration]
{endif}
{else}
G1 X[x_after_toolchange] Y[y_after_toolchange] Z[z_after_toolchange] F12000
{endif}
M621 S[next_extruder]A

M622.1 S0 ;for prev version, default skip
M1002 judge_flag powerloss_resume_flag
M622 J1
M983.3 F{filament_max_volumetric_speed[next_extruder]/2.4} A0.4 R{retract_length_toolchange[filament_map[next_extruder]-1]}
M400
{if wipe_avoid_perimeter}
G1 Y320 F30000
G1 X{wipe_avoid_pos_x} F30000
{endif}
G1 Y295 F30000
G1 Y265 F18000
G1 Z{max_layer_z + 3.0} F3000
{if layer_z <= (initial_layer_print_height + 0.001)}
M204 S[initial_layer_acceleration]
{else}
M204 S[default_acceleration]
{endif}
M1002 set_flag powerloss_resume_flag=0
M623

M993 A3 B3 C3 ; nozzle cam detection allow status restore.

{if (filament_type[next_extruder] == "PLA") ||  (filament_type[next_extruder] == "PETG")
 ||  (filament_type[next_extruder] == "PLA-CF")  ||  (filament_type[next_extruder] == "PETG-CF")}
M1015.4 S1 K1 H[nozzle_diameter] ;enable E air printing detect
{else}
M1015.4 S0 ; disable E air printing detect
{endif}

M620.6 I[next_extruder] W1 ;enable ams air printing detect
M1002 gcode_claim_action : 0
