;======== H2C filament_change ========
;===== 20260413 =====
M993 A2 B2 C2 ; nozzle cam detection allow status save.
M993 A0 B0 C0 ; nozzle cam detection not allowed.

{if (filament_type[next_filament_id] == "PLA") ||  (filament_type[next_filament_id] == "PETG")
 ||  (filament_type[next_filament_id] == "PLA-CF")  ||  (filament_type[next_filament_id] == "PETG-CF")}
M1015.4 S1 K0 ;disable E air printing detect
{else}
M1015.4 S0 ; disable E air printing detect
{endif}

M620 S[next_filament_id]A H[next_hotend]
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

{if wipe_tower_center_pos_valid}
    M620.14 X[wipe_tower_center_pos_x] Y[wipe_tower_center_pos_y]
{else}
    M620.14 X95.5 Y336
{endif}

{if ((filament_type[current_filament_id] == "PLA") || (filament_type[current_filament_id] == "PLA-CF") || (filament_type[current_filament_id] == "PETG")) && (nozzle_diameter_at_nozzle_id[current_nozzle_id] == 0.2)}
M620.10 A0 F74.8347 L[flush_length] H{nozzle_diameter_at_nozzle_id[current_nozzle_id]} T{flush_temperatures[current_filament_id]} P[old_filament_temp] S1
{else}
M620.10 A0 F{flush_volumetric_speeds[current_filament_id]/2.4053*60*0.8} L[flush_length] H{nozzle_diameter_at_nozzle_id[current_nozzle_id]} T{flush_temperatures[current_filament_id]} P[old_filament_temp] S1
{endif}

{if ((filament_type[next_filament_id] == "PLA") || (filament_type[next_filament_id] == "PLA-CF") || (filament_type[next_filament_id] == "PETG")) && (nozzle_diameter_at_nozzle_id[next_nozzle_id] == 0.2)}
M620.10 A1 F74.8347 L[flush_length] H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} T{flush_temperatures[next_filament_id]} P[new_filament_temp] S1
{else}
M620.10 A1 F{flush_volumetric_speeds[next_filament_id]/2.4053*60*0.8} L[flush_length] H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} T{flush_temperatures[next_filament_id]} P[new_filament_temp] S1
{endif}

{if long_retraction_when_cut}
M620.11 P1 I[current_filament_id] B[current_hotend] E-{retraction_distance_when_cut} F{max((flush_volumetric_speeds[current_filament_id]/2.4053*60), 200)}
{else}
M620.11 P0 I[current_filament_id] B[current_hotend] E0
{endif}


M620.15 P[filament_pre_cooling_temperature_nc[next_filament_id]]
M620.15 C{new_filament_temp - filament_cooling_before_tower[next_filament_id]}
M620.11 O1 T[filament_retract_length_nc]

{if long_retraction_when_ec}
M620.11 K1 I[current_filament_id] B[current_hotend] R{retraction_distance_when_ec} F{max((flush_volumetric_speeds[current_filament_id]/2.4053*60), 200)}
{else}
M620.11 K0 I[current_filament_id] B[current_hotend] R0
{endif}

M620.15 C{new_filament_temp - filament_cooling_before_tower[next_filament_id]}

M628 S1
{if filament_type[current_filament_id] == "TPU"}
M620.11 S0 L0 I[current_filament_id] B[current_hotend] E-{retraction_distances_when_cut[current_filament_id]} F{max((flush_volumetric_speeds[current_filament_id]/2.4053*60), 200)}
{else}
{if (filament_type[current_filament_id] == "PA") || (filament_type[current_filament_id] == "PA-GF")}
M620.11 S1 L0 I[current_filament_id] B[current_hotend] R4 D2 E-{retraction_distances_when_cut[current_filament_id]} F{max((flush_volumetric_speeds[current_filament_id]/2.4053*60), 200)}
{else}
M620.11 S1 L0 I[current_filament_id] B[current_hotend] R10 D8 E-{retraction_distances_when_cut[current_filament_id]} F{max((flush_volumetric_speeds[current_filament_id]/2.4053*60), 200)}
{endif}
{endif}
M629

{if (filament_type[current_filament_id] == "TPU") && (filament_map[current_filament_id] == 2) && (nozzle_volume_types[current_nozzle_id] != "TPU High Flow")}
M620.11 H2 C331
{else}
M620.11 H0
{endif}

{if  (nozzle_volume_types[current_nozzle_id] == "TPU High Flow") && (filament_map[current_filament_id] == 2) && (filament_map[next_filament_id] == 1)}
;sw from R2L&TPU kit, travel run a distance for sketch TPU
G1 X30 Y30 F5000
M400
G1 X300 Y30 F5000
M400
{endif}

T[next_filament_id] H[next_hotend]

;deretract
{if filament_type[next_filament_id] == "TPU"}
{else}
{if (filament_type[next_filament_id] == "PA") || (filament_type[next_filament_id] == "PA-GF")}
;VG1 E1 F{max(new_filament_e_feedrate, 200)}
;VG1 E1 F{max(new_filament_e_feedrate/2, 100)}
{else}
;VG1 E4 F{max(new_filament_e_feedrate, 200)}
;VG1 E4 F{max(new_filament_e_feedrate/2, 100)}
{endif}
{endif}

; VFLUSH_START

{if flush_length>41.5}
;VG1 E41.5 F{min(old_filament_e_feedrate,new_filament_e_feedrate)}
;VG1 E{flush_length-41.5} F{new_filament_e_feedrate}
{else}
;VG1 E{flush_length} F{min(old_filament_e_feedrate,new_filament_e_feedrate)}
{endif}

SYNC T{ceil(flush_length / 125) * 5}

; compensate for heating and cooling
{if flush_length > 0}
{if flush_temperatures[next_filament_id] > new_filament_temp}
SYNC T{(flush_temperatures[next_filament_id]-(new_filament_temp - filament_cooling_before_tower[next_filament_id]))/hotend_cooling_rate[filament_map[next_filament_id]-1]}
SYNC T{(flush_temperatures[next_filament_id]-(new_filament_temp - filament_cooling_before_tower[next_filament_id]))/hotend_heating_rate[filament_map[next_filament_id]-1]}
{else}
SYNC T{(new_filament_temp - filament_cooling_before_tower[next_filament_id] -flush_temperatures[next_filament_id])/hotend_cooling_rate[filament_map[next_filament_id]-1]}
SYNC T{(new_filament_temp - filament_cooling_before_tower[next_filament_id] -flush_temperatures[next_filament_id])/hotend_heating_rate[filament_map[next_filament_id]-1]}
{endif}
{endif}

; VFLUSH_END

M1002 set_filament_type:{filament_type[next_filament_id]}

M400
M83
{if next_filament_id < 255}


M620.10 R{new_extruder_retracted_length}

{if (print_sequence == "by object" && !has_wipe_tower)}
M628 S0 F1 L10.0
; VFLUSH_START
;VG1 E10 F[new_filament_e_feedrate]
; VFLUSH_END
{else}
M628 S0
{endif}
;VM109 S[new_filament_temp]

M629
M400

;prime_tower_interface
{if is_prime_tower_interface && filament_tower_interface_purge_volume !=0}
G150.1
M620.13 W0 L{filament_tower_interface_purge_volume} T{filament_tower_interface_print_temp} R0.0
{endif}
;prime_tower_interface

M983.3 F{filament_max_volumetric_speed[next_filament_id]/2.4} A0.4 R{new_extruder_retracted_length}


M400
{if wipe_avoid_perimeter}
G387 Y320 J1 F10000
G1 X{wipe_avoid_pos_x} F30000
{endif}
G387 Y295 J1 F30000
G387 Y265 J1 F18000
G1 Z{max_layer_z + 3.0} F3000
{if layer_z <= (initial_layer_print_height + 0.001)}
M204 S[initial_layer_acceleration]
{else}
M204 S[default_acceleration]
{endif}
{else}
G1 X[x_after_toolchange] Y[y_after_toolchange] Z[z_after_toolchange] F12000
{endif}
M621 S[next_filament_id]A

M622.1 S0 ;for prev version, default skip
M1002 judge_flag powerloss_resume_flag
M622 J1
M983.3 F{filament_max_volumetric_speed[next_filament_id]/2.4} A0.4 R{new_extruder_retracted_length}
M400
{if wipe_avoid_perimeter}
G387 Y320 J1 F10000
G1 X{wipe_avoid_pos_x} F30000
{endif}
G387 Y295 J1 F30000
G387 Y265 J1 F18000
G1 Z{max_layer_z + 3.0} F3000
{if layer_z <= (initial_layer_print_height + 0.001)}
M204 S[initial_layer_acceleration]
{else}
M204 S[default_acceleration]
{endif}
M1002 set_flag powerloss_resume_flag=0
M623

M993 A3 B3 C3 ; nozzle cam detection allow status restore.

{if (filament_type[next_filament_id]  == "TPU")}
M1015.3 S1;enable tpu clog detect
{else}
M1015.3 S0;disable tpu clog detect
{endif}

{if (filament_type[next_filament_id] == "PLA") ||  (filament_type[next_filament_id] == "PETG")
 ||  (filament_type[next_filament_id] == "PLA-CF")  ||  (filament_type[next_filament_id] == "PETG-CF")}
M1015.4 S1 K1 H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} ;enable E air printing detect
{else}
M1015.4 S0 ; disable E air printing detect
{endif}

M620.6 I[next_filament_id] H[next_hotend] W1 ;enable ams air printing detect
M620 O{toolchange_count + 1}
M1002 gcode_claim_action : 0