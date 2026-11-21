;======== A2L filament_change gcode ==========
;===== 2026/05/26 =====

M620 S[next_filament_id]A
M204 S9000
{if toolchange_count > 1 && (z_hop_types[current_filament_id] == 0 || z_hop_types[current_filament_id] == 3)}
G17
G2 Z{z_after_toolchange + 0.4} I0.86 J0.86 P1 F10000 ; spiral lift a little from second lift
{endif}

;nozzle_change_gcode

G1 Z{max_layer_z + 3.0} F1200

M400
M106 P1 S0

{if toolchange_count == 2}
; get travel path for change filament
;M620.1 X[travel_point_1_x] Y[travel_point_1_y] F21000 P0
;M620.1 X[travel_point_2_x] Y[travel_point_2_y] F21000 P1
;M620.1 X[travel_point_3_x] Y[travel_point_3_y] F21000 P2
{endif}

{if ((filament_type[current_filament_id] == "PLA") || (filament_type[current_filament_id] == "PLA-CF") || (filament_type[current_filament_id] == "PETG") || (filament_type[current_filament_id] == "PETG-CF")) && (nozzle_diameter_at_nozzle_id[current_nozzle_id] == 0.2)}
M620.10 A0 F74.8347 L[flush_length] H{nozzle_diameter_at_nozzle_id[current_nozzle_id]} T{flush_temperatures[current_filament_id]} P[old_filament_temp] S1
{else}
M620.10 A0 F{flush_volumetric_speeds[current_filament_id]/2.4053*60} L[flush_length] H{nozzle_diameter_at_nozzle_id[current_nozzle_id]} T{flush_temperatures[current_filament_id]} P[old_filament_temp] S1
{endif}

{if ((filament_type[next_filament_id] == "PLA") || (filament_type[next_filament_id] == "PLA-CF") || (filament_type[next_filament_id] == "PETG") || (filament_type[next_filament_id] == "PETG-CF")) && (nozzle_diameter_at_nozzle_id[next_nozzle_id] == 0.2)}
M620.10 A1 F74.8347 L[flush_length] H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} T{flush_temperatures[next_filament_id]} P[new_filament_temp] S1
{else}
M620.10 A1 F{flush_volumetric_speeds[next_filament_id]/2.4053*60} L[flush_length] H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} T{flush_temperatures[next_filament_id]} P[new_filament_temp] S1
{endif}

{if long_retraction_when_cut}
M620.11 P1 L0 I[current_filament_id] E-{retraction_distance_when_cut} F{max((flush_volumetric_speeds[current_filament_id]/2.4053*60), 200)}
{else}
M620.11 P0 L0 I[current_filament_id] E0
{endif}

M620.11 K0 I[current_filament_id] R0


T[next_filament_id]

;deretract
{if filament_type[next_filament_id] == "TPU"}
{else}
;VG1 E4 F{max(new_filament_e_feedrate, 200)}
;VG1 E4 F{max(new_filament_e_feedrate/2, 100)}
{endif}


; VFLUSH_START

{if flush_length>41.5}
;VG1 E41.5 F{min(old_filament_e_feedrate,new_filament_e_feedrate)}
;VG1 E{flush_length-41.5} F{new_filament_e_feedrate}
{else}
;VG1 E{flush_length} F{min(old_filament_e_feedrate,new_filament_e_feedrate)}
{endif}

SYNC T{ceil(flush_length / 80) * 7.5 + 6.5}

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
M620.10 R{retract_length_toolchange[filament_map[next_filament_id]-1]}
M628 S0
;VM109 S[new_filament_temp]
M629
M400
M983.3 F{filament_max_volumetric_speed[next_filament_id]/2.4} A0.4 R{retract_length_toolchange[filament_map[next_filament_id]-1]}
M400

G1 Z{max_layer_z + 3.0} F3000
{if layer_z <= (initial_layer_print_height + 0.001)}
M204 S[initial_layer_acceleration]
{else}
M204 S[travel_acceleration]
{endif}

{else}
G1 X[x_after_toolchange] Y[y_after_toolchange] Z[z_after_toolchange] F12000
{endif}

M621 S[next_filament_id]A

M622.1 S0 ;for prev version, default skip
M1002 judge_flag powerloss_resume_flag
M622 J1
M983.3 F{filament_max_volumetric_speed[next_filament_id]/2.4} A0.4 R{retract_length_toolchange[filament_map[next_filament_id]-1]}
M400
G1 Z{max_layer_z + 3.0} F3000
{if layer_z <= (initial_layer_print_height + 0.001)}
M204 S[initial_layer_acceleration]
{else}
M204 S[travel_acceleration]
{endif}
M1002 set_flag powerloss_resume_flag=0
M623

{if (filament_type[next_filament_id] == "TPU")}
M1015.3 S1 H{nozzle_diameter_at_nozzle_id[next_nozzle_id]};enable tpu clog detect
{else}
M1015.3 S0;disable tpu clog detect
{endif}

{if (filament_type[next_filament_id] == "PLA") ||  (filament_type[next_filament_id] == "PETG")
 ||  (filament_type[next_filament_id] == "PLA-CF")  ||  (filament_type[next_filament_id] == "PETG-CF")}
M1015.4 S1 K1 H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} ;enable E air printing detect
{else}
M1015.4 S0 K0 H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} ;disable E air printing detect
{endif}

{if ((filament_type[next_filament_id] == "PETG") || (filament_type[next_filament_id] == "PETG-CF") || (filament_type[next_filament_id] == "TPU") || (filament_type[next_filament_id] == "TPU-AMS"))}
  G390.7 M6 G4 C3
{else}
  G390.7 M6 G6 C3
{endif}

M620.6 I[next_filament_id] W1 ;enable ams air printing detect

;Set the filament gear warning temperature
{if (temperature_vitrification[next_filament_id] <= 50)}
    {if ((filament_ids[next_filament_id]=="GFA05") || (filament_ids[next_filament_id]=="GFA06"))}
        M142 P1 O45; set PLASILK gear warning temperature when filament change
    {else}
        M142 P1 O60; set PLA/PLACF/PLAAERO/PVA/TPU gear warning temperature when filament change
    {endif}
{else}
    M142 P1 O100 ; set gear warning temperature when filament change
{endif}
