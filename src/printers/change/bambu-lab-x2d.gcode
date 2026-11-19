;======== X2D filament_change gcode ==========
;===== 2026/07/01 =====

M620 S[next_filament_id]A B H[next_hotend]
;M204 S9000
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

{if ((filament_type[current_filament_id] == "PLA") || (filament_type[current_filament_id] == "PLA-CF") || (filament_type[current_filament_id] == "PETG")) && (nozzle_diameter_at_nozzle_id[current_nozzle_id] == 0.2)}
M620.10 A0 F74.8347 L[flush_length] H{nozzle_diameter_at_nozzle_id[current_nozzle_id]} T{flush_temperatures[current_filament_id]} P[old_filament_temp] S1
{else}
M620.10 A0 F{flush_volumetric_speeds[current_filament_id]/2.4053*60} L[flush_length] H{nozzle_diameter_at_nozzle_id[current_nozzle_id]} T{flush_temperatures[current_filament_id]} P[old_filament_temp] S1
{endif}

{if ((filament_type[next_filament_id] == "PLA") || (filament_type[next_filament_id] == "PLA-CF") || (filament_type[next_filament_id] == "PETG")) && (nozzle_diameter_at_nozzle_id[next_nozzle_id] == 0.2)}
M620.10 A1 F74.8347 L[flush_length] H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} T{flush_temperatures[next_filament_id]} P[new_filament_temp] S1
{else}
M620.10 A1 F{flush_volumetric_speeds[next_filament_id]/2.4053*60} L[flush_length] H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} T{flush_temperatures[next_filament_id]} P[new_filament_temp] S1
{endif}

M620.15 C{new_filament_temp - filament_cooling_before_tower[next_filament_id]}

{if long_retraction_when_cut}
M620.11 P1 L0 I[current_filament_id] B[current_hotend] E-{retraction_distance_when_cut} F{max((flush_volumetric_speeds[current_filament_id]/2.4053*60), 200)}
{else}
M620.11 P0 L0 I[current_filament_id] B[current_hotend] E0
{endif}

{if long_retraction_when_ec}
M620.11 K1 I[current_filament_id] B[current_hotend] R{retraction_distance_when_ec} F{max((flush_volumetric_speeds[current_filament_id]/2.4053*60), 200)}
{else}
M620.11 K0 I[current_filament_id] B[current_hotend] R0
{endif}

M620.22 I[next_filament_id] P1    ; enable remote extruder runout auto purge.

T[next_filament_id] H[next_hotend]

;deretract
{if filament_type[next_filament_id] == "TPU"}
{else}
{if filament_type[next_filament_id] == "PA"}
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

;prime_tower_interface
{if is_prime_tower_interface && filament_tower_interface_purge_volume !=0}
G150.1
M620.13 W0 L{filament_tower_interface_purge_volume} T{filament_tower_interface_print_temp} R0.0
{endif}
;prime_tower_interface

M983.3 F{filament_max_volumetric_speed[next_filament_id]/2.4} A0.4 R{retract_length_toolchange[filament_map[next_filament_id]-1]}

M400

G1 Z{max_layer_z + 3.0} F3000

{else}
G1 X[x_after_toolchange] Y[y_after_toolchange] Z[z_after_toolchange] F12000
{endif}


M621 S[next_filament_id]A B

M622.1 S0 ;for prev version, default skip
M1002 judge_flag powerloss_resume_flag
M622 J1
M983.3 F{filament_max_volumetric_speed[next_filament_id]/2.4} A0.4 R{retract_length_toolchange[filament_map[next_filament_id]-1]}
M400
G1 Z{max_layer_z + 3.0} F3000
M1002 set_flag powerloss_resume_flag=0
M623

M620.6 I[next_filament_id] H[next_hotend] W1 ;enable ams air printing detect

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

{if layer_z <= (initial_layer_print_height + 0.001)}
M204 S[initial_layer_acceleration]
{else}
M204 S[travel_acceleration]
{endif}

G1 Y256 F18000


{if (overall_chamber_temperature < 40)}
{if (layer_num + 1 <= close_additional_fan_first_x_layers[next_filament_id])}
    M106 P2 S{first_x_layer_fan_speed[next_filament_id]*255.0/100.0 };set first x_layer fan
	M106 P10 S{first_x_layer_fan_speed[next_filament_id]*255.0/100.0 };set first x_layer fan
{elsif (layer_num + 1 < additional_fan_full_speed_layer[next_filament_id] && additional_fan_full_speed_layer[next_filament_id] > close_additional_fan_first_x_layers[next_filament_id])}
    M106 P2 S{(first_x_layer_fan_speed[next_filament_id] + (additional_cooling_fan_speed[next_filament_id] - first_x_layer_fan_speed[next_filament_id]) * (layer_num + 1 - close_additional_fan_first_x_layers[next_filament_id]) / max(additional_fan_full_speed_layer[next_filament_id] - close_additional_fan_first_x_layers[next_filament_id], 1)) * 255.0/100.0}
	M106 P10 S{(first_x_layer_fan_speed[next_filament_id] + (additional_cooling_fan_speed[next_filament_id] - first_x_layer_fan_speed[next_filament_id]) * (layer_num + 1 - close_additional_fan_first_x_layers[next_filament_id]) / max(additional_fan_full_speed_layer[next_filament_id] - close_additional_fan_first_x_layers[next_filament_id], 1)) * 255.0/100.0}
{else}
    {if (min_vitrification_temperature <= 50)}
        {if (nozzle_diameter_at_nozzle_id[current_nozzle_id] == 0.2)}
            M142 P1 R30 S40 U{max_additional_fan/100.0} V1.0 O45; set PLA/TPU ND0.2 chamber autocooling
        {else}
            M142 P1 R30 S40 U{max_additional_fan/100.0} V1.0 O45; set PLA/TPU ND0.4 chamber autocooling
        {endif}
    {else}
        {if (!is_all_bbl_filament)}
            M142 P1 R40 S45 U{max_additional_fan/100.0} V0.5 O50; set third-party PETG chamber 
        {else}
            {if (nozzle_diameter_at_nozzle_id[current_nozzle_id] == 0.2)}
                M142 P1 R45 S50 U{max_additional_fan/100.0} V0.5 O50; set PETG ND0.2 chamber autocooling
            {else}
                M142 P1 R50 S55 U{max_additional_fan/100.0} V0.5 O55; set PETG ND0.4 chamber autocooling
            {endif}
        {endif}
    {endif}
{endif}
{endif}
;not set fan changing filament
