;======== H3C ======
;===== 20261028 =====
M650.8 C2
M620 Q{toolchange_count + 1}
M620 S[next_filament_id]A
M1002 gcode_claim_action : 4
M204 S9000

M1002 set_next_filament_id:{filament_ids[next_filament_id]}

G1 Z{max_layer_z + 3.0} F3000

M400
M106 P1 S0
M106 P2 S0
M106 P10 S0

{if ((filament_type[current_filament_id] == "PLA") || (filament_type[current_filament_id] == "PLA-CF") || (filament_type[current_filament_id] == "PETG")) && (nozzle_diameter_at_nozzle_id[current_nozzle_id] == 0.2)}
M620.10 A0 F74.8347 L[flush_length] H{nozzle_diameter_at_nozzle_id[current_nozzle_id]} T{flush_temperatures[current_filament_id]} P{nozzle_temperature[current_filament_id]} S1
{else}
M620.10 A0 F{flush_volumetric_speeds[current_filament_id]/(filament_diameter[current_filament_id]*filament_diameter[current_filament_id]*3.14159/4)*60} L[flush_length] H{nozzle_diameter_at_nozzle_id[current_nozzle_id]} T{flush_temperatures[current_filament_id]} P{nozzle_temperature[current_filament_id]} S1
{endif}

{if ((filament_type[next_filament_id] == "PLA") || (filament_type[next_filament_id] == "PLA-CF") || (filament_type[next_filament_id] == "PETG")) && (nozzle_diameter_at_nozzle_id[next_nozzle_id] == 0.2)}
M620.10 A1 F74.8347 L[flush_length] H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} T{flush_temperatures[next_filament_id]} P{nozzle_temperature[next_filament_id]} S1 V{filament_max_volumetric_speed[next_filament_id]/(filament_diameter[next_filament_id]*filament_diameter[next_filament_id]*3.14159/4)}
{else}
M620.10 A1 F{flush_volumetric_speeds[next_filament_id]/(filament_diameter[next_filament_id]*filament_diameter[next_filament_id]*3.14159/4)*60} L[flush_length] H{nozzle_diameter_at_nozzle_id[next_nozzle_id]} T{flush_temperatures[next_filament_id]} P{nozzle_temperature[next_filament_id]} S1 V{filament_max_volumetric_speed[next_filament_id]/(filament_diameter[next_filament_id]*filament_diameter[next_filament_id]*3.14159/4)}
{endif}

{if ((filament_type[next_filament_id] == "PVA") && (enable_prime_tower))}
M620.15 C{nozzle_temperature[next_filament_id] - 30}
{else}
M620.15 C{nozzle_temperature[next_filament_id]}
{endif}

{if long_retraction_when_cut}
M620.11 P1 I[current_filament_id] E-{retraction_distance_when_cut} F{max((flush_volumetric_speeds[current_filament_id]/(filament_diameter[current_filament_id]*filament_diameter[current_filament_id]*3.14159/4)*60), 200)}
{else}
M620.11 P0 I[current_filament_id] E0
{endif}

{if long_retraction_when_ec}
M620.11 K1 I[current_filament_id] R{retraction_distance_when_ec} N4 F1800
{else}
M620.11 K0 I[current_filament_id] R0
{endif}


{if (fins_extrude_safe_temp[next_filament_id]) < 30}
M650.11 E0
{else}
M650.11 E1
M650.11 A{fins_extrude_safe_temp[next_filament_id]} B{fins_extrude_safe_temp[next_filament_id] - 5}
{endif}


{if filament_type[current_filament_id] == "TPU"}
M650.5 P0
{else}
M650.5 P1
{endif}
M650.5 W L20 F600

T[next_filament_id]


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

{if ((filament_type[next_filament_id] == "PVA") && (enable_prime_tower))}
M104 S{nozzle_temperature[next_filament_id]}
{endif}

;prime_tower_interface
{if is_prime_tower_interface && filament_tower_interface_purge_volume !=0}
G150.1
M620.13 W0 L{filament_tower_interface_purge_volume} T{filament_tower_interface_print_temp} R0.0
{endif}
;prime_tower_interface

M983.3 F{filament_max_volumetric_speed[next_filament_id]/2.4} A{nozzle_diameter_at_nozzle_id[next_nozzle_id]} R{retract_length_toolchange[filament_map[next_filament_id]-1]}

M400

G1 Z{max_layer_z + 3.0} F3000
{if layer_z <= (initial_layer_print_height + 0.001)}
M204 S[initial_layer_travel_acceleration]
{else}
M204 S[travel_acceleration]
{endif}
{else}
G1 X[x_after_toolchange] Y[y_after_toolchange] Z[z_after_toolchange] F12000
{endif}
M621 S[next_filament_id]A

{if (filament_ids[next_filament_id] == "GFU06")}
M1015.4 L15
M17 E1.8
M1015.5 S1
{elsif (filament_ids[next_filament_id] == "GFU04")}
M1015.4 L15
M17 E0.25
M1015.5 S0
{elsif (filament_ids[next_filament_id] == "GFU03")}
M1015.4 L15
M17 E0.4
M1015.5 S0
{else}
M1015.4 L10
M17 E1.8
M1015.5 S1
{endif}

M622.1 S0 ;for prev version, default skip
M1002 judge_flag powerloss_resume_flag
M622 J1
M983.3 F{filament_max_volumetric_speed[next_filament_id]/2.4} A{nozzle_diameter_at_nozzle_id[next_nozzle_id]} R{retract_length_toolchange[filament_map[next_filament_id]-1]}
M400

G1 Z{max_layer_z + 3.0} F3000
{if layer_z <= (initial_layer_print_height + 0.001)}
M204 S[initial_layer_travel_acceleration]
{else}
M204 S[travel_acceleration]
{endif}
M1002 set_flag powerloss_resume_flag=0
M623

G387 Y295 J1 F60000
G387 Y265 J1 F18000

M620.6 I[next_filament_id] H[next_hotend] W1 ;enable ams air printing detect
M620 O{toolchange_count + 1}
M1002 gcode_claim_action : 0
M650.8 C1
