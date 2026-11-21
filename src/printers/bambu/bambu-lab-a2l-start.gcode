;M1002 set_flag extrude_cali_flag=1
;M1002 set_flag g29_before_print_flag=1
;M1002 set_flag build_plate_detect_flag=1
;M1002 set_flag bed_heat_stable_wait_flag=1

;======== A2L start gcode==========
;===== 2026/07/14 =====
T1000 O0
M1002 gcode_claim_action : 2
{if hold_chamber_temp_for_flat_print && (bed_temperature_initial_layer_single == 55)}
    M140 S65
{else}
    M140 S[bed_temperature_initial_layer_single] ; heat heatbed first
{endif}

M993 A0 B0 C0 ; nozzle cam detection not allowed.
M400

;=====printer start sound ===================
M17
M400 S1
M1006 S1
M1006 A53 B9 L30 C53 D9 M30 E53 F9 N30
M1006 A56 B9 L30 C56 D9 M30 E56 F9 N30
M1006 A61 B9 L30 C61 D9 M30 E61 F9 N30
M1006 A53 B9 L30 C53 D9 M30 E53 F9 N30
M1006 A56 B9 L30 C56 D9 M30 E56 F9 N30
M1006 A61 B18 L30 C61 D18 M30 E61 F18 N30
M1006 W
;=====printer start sound ===================

  M620 M ;enable remap
  G389

;===== avoid end stop =================
  G91
  G380 S2 Z22 F1200
  G380 S2 Z-12 F1200
  G90
;===== avoid end stop =================

;===== reset machine status =================
  M204 S10000
  M630 S0 P1
  G90
  M17 D ; reset motor current to default
  M960 S5 P1 ; turn on logo lamp
  M220 S100 ;Reset Feedrate
  M221 S100 ;Reset Flowrate
  M73.2   R1.0 ;Reset left time magnitude
  G29.1 Z{+0.0} ; clear z-trim value first
  M983.1 M1
  M982.2 S1 ; turn on cog noise reduction
  M983.4 S0
;===== reset machine status =================
;Set the filament gear warning temperature
{if (temperature_vitrification[initial_filament_id] <= 50)}
    {if ((filament_ids[initial_filament_id]=="GFA05") || (filament_ids[initial_filament_id]=="GFA06"))}
        M142 P1 O45; set PLASILK gear warning temperature when start
    {else}
        M142 P1 O60; set PLA/PLACF/PLAAERO/PVA/TPU gear warning temperature when start
    {endif}
{else}
    M142 P1 O100 ; set gear warning temperature when start
{endif}
;===== start to heat heatbed & hotend==========
  M1002 set_filament_type:{filament_type[initial_no_support_filament_id]}
  M104 S140 A

  G29.2 S0 ; avoid invalid abl data

;===== first homing start =====
  M1002 gcode_claim_action : 13
  M105
  G28 X Z P0 T300 W
  G150.3
  G1 Z1.3 F1200
  G150.1 F16000 ; wipe mouth to avoid filament stick to heatbed
  G90
  M400
;===== first homing end =====


;===== detection start =====
;===== build_plate_detect_flag start =====
M1002 judge_flag build_plate_detect_flag
M622 S1
  G91
  G1 Z5 F1200
  G90
  G0 X15 F30000
  G0 Y319 F3000
  G91
  G1 Z-5 F1200
  G28 Z P0 T140
  G1 F1200
  G39.4
  G90
  G1 Z5 F1200
M623
;===== build_plate_detect_flag end =====
;===== detection end =====


;===== hotend hotbed pre-heat start =====
  M104 S{nozzle_temperature_initial_layer[initial_no_support_filament_id]-80} A ; rise nozzle temp in advance

  G90
  G1 Y220 F3000 ; Put away the heated bed to prevent collisions

  {if hold_chamber_temp_for_flat_print && (bed_temperature_initial_layer_single == 55)}
      M190 S65
  {else}
      M190 S[bed_temperature_initial_layer_single]
  {endif}
;===== hotend hotbed pre-heat end =====


;===== prepare print temperature and material ==========
  M400
  M211 X0 Y0 Z0 ;turn off soft endstop
  M975 S1 ; turn on input shaping

  G29.2 S0 ; avoid invalid abl data
  G150.3
{if ((filament_type[initial_no_support_filament_id] == "PLA") || (filament_type[initial_no_support_filament_id] == "PLA-CF") || (filament_type[initial_no_support_filament_id] == "PETG") || (filament_type[initial_no_support_filament_id] == "PETG-CF")) && (nozzle_diameter_at_nozzle_id[initial_nozzle_id] == 0.2)}
M620.10 A0 F74.8347 H{nozzle_diameter_at_nozzle_id[initial_nozzle_id]} T{flush_temperatures[initial_no_support_filament_id]} P{nozzle_temperature_initial_layer[initial_no_support_filament_id]} S1
M620.10 A1 F74.8347 H{nozzle_diameter_at_nozzle_id[initial_nozzle_id]} T{flush_temperatures[initial_no_support_filament_id]} P{nozzle_temperature_initial_layer[initial_no_support_filament_id]} S1
{else}
M620.10 A0 F{flush_volumetric_speeds[initial_no_support_filament_id]/2.4053*60} H{nozzle_diameter_at_nozzle_id[initial_nozzle_id]} T{flush_temperatures[initial_no_support_filament_id]} P{nozzle_temperature_initial_layer[initial_no_support_filament_id]} S1
M620.10 A1 F{flush_volumetric_speeds[initial_no_support_filament_id]/2.4053*60} H{nozzle_diameter_at_nozzle_id[initial_nozzle_id]} T{flush_temperatures[initial_no_support_filament_id]} P{nozzle_temperature_initial_layer[initial_no_support_filament_id]} S1
{endif}

 M620.11 P0 L0 I[initial_no_support_filament_id] E0
 M620.11 K0 I[initial_no_support_filament_id] R0

  M620 S[initial_no_support_filament_id]A   ; switch material if AMS exist
  M1002 gcode_claim_action : 4
  M1002 set_filament_type:UNKNOWN
  M400
  T[initial_no_support_filament_id]
  M400
  M628 S0
  M629
  M400
  M1002 set_filament_type:{filament_type[initial_no_support_filament_id]}
  M621 S[initial_no_support_filament_id]A
  M104 S{nozzle_temperature_initial_layer[initial_no_support_filament_id]}
  M400
  M106 P1 S0
  M400
  G29.2 S1
{if ((filament_type[initial_no_support_filament_id] == "PETG") || (filament_type[initial_no_support_filament_id] == "PETG-CF") || (filament_type[initial_no_support_filament_id] == "TPU") || (filament_type[initial_no_support_filament_id] == "TPU-AMS"))}
  G390.7 M6 G4 C3
{else}
  G390.7 M6 G6 C3
{endif}
;===== prepare print temperature and material ==========


;===== auto extrude cali start =========================
M975 S1
M1002 judge_flag extrude_cali_flag
  M622 J0
    M983.3 F{filament_max_volumetric_speed[initial_no_support_filament_id]/2.4} A0.4 ; cali dynamic extrusion compensation
  M623

  M622 J1
    M1002 set_filament_type:{filament_type[initial_no_support_filament_id]}
    M1002 gcode_claim_action : 8
    M109 S{nozzle_temperature[initial_no_support_filament_id]}
    G90
    M83
    M983.3 F{filament_max_volumetric_speed[initial_no_support_filament_id]/2.4} A0.4 ; cali dynamic extrusion compensation
    M400
  M623

  M622 J2
    M1002 set_filament_type:{filament_type[initial_no_support_filament_id]}
    M1002 gcode_claim_action : 8
    M109 S{nozzle_temperature[initial_no_support_filament_id]}
    G90
    M83
    M983.3 F{filament_max_volumetric_speed[initial_no_support_filament_id]/2.4} A0.4 ; cali dynamic extrusion compensation
    M400
  M623
;===== auto extrude cali end =========================


  {if filament_type[initial_filament_id] == "TPU" || filament_type[initial_filament_id] == "PVA"}
  {else}
    M83
    G1 E-3 F1800
    M400 P500
  {endif}
  G0 Z1.3 F1200
  G150.2
  G150.1 F16000

  G91
  G1 X20 F12000 ; move away from the trash bin
  G90
  M400


;===== wipe nozzle start =====
  M1002 gcode_claim_action : 14
  G150 T{nozzle_temperature_initial_layer[initial_no_support_filament_id]}
  M400
  M109 S140 A
  M106 P1 S255
  G91
  G1 Z1.3 F1200
  G90
  M400 S1
  ;======== enhance brush nozzle start =====
  G150.1 F16000
  G91
  G1 Y5   F5000
  G1 X-20 F16000
  G1 Y-10 F5000
  G1 X-20 F16000
  G1 Y10  F5000
  G1 X20  F16000
  G1 Y-10 F5000
  G1 X20  F16000
  G1 Y5   F5000
  G90
  G150.1 F16000
  G150.3
  ;======== enhance brush nozzle end =====
  M106 P1 S0
;===== wipe nozzle end =====

;===== mech mode sweep start =====
  M1002 gcode_claim_action : 3
  G90
  G1 Z5 F1200
  G1 X165 Y160 F20000
  M400 P200
  M970.3 Q1 A5 K0 O3
  M970.3 Q1 B1
  M970.2 Q1 K1 W52 Z0.1 B30 ;
  M970.3 Q0 A10 K0 O1
  M970.3 Q0 B1
  M970.2 Q0 K1 W40 Z0.1 B20 ;
  M974 Q0 S2 P0
  M974 Q1 S2 P0
  M975 S1 R1 M1
  M400
  G1 X155 F3000
  G150.3
;===== mech mode sweep end =====


;===== bed leveling ==================================

  {if hold_chamber_temp_for_flat_print && (bed_temperature_initial_layer_single == 55)}
    M190 S65
  {else}
    M190 S[bed_temperature_initial_layer_single] ; ensure bed temp
  {endif}
  M109 S140 A


  {if hold_chamber_temp_for_flat_print && (bed_temperature_initial_layer_single == 55)}
    M1002 gcode_claim_action : 58
    SYNC R0 T600
    M1030 S500 ; action before has done 200s insulation
    M1030 C
  {else}
    M1002 judge_flag g29_before_print_flag
    M622 J1
        M1002 judge_flag bed_heat_stable_wait_flag
        M622 J1
          {if (bed_temperature_initial_layer_single > 35)}
            M1002 gcode_claim_action : 58
            G29.30 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} I{first_layer_print_size[0]} J{first_layer_print_size[1]}
          {endif}
        M623
    M623
    M622 J2
        M1002 judge_flag bed_heat_stable_wait_flag
        M622 J1
          {if (bed_temperature_initial_layer_single > 35)}
            M1002 gcode_claim_action : 58
            G29.30 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} I{first_layer_print_size[0]} J{first_layer_print_size[1]}
          {endif}
        M623
    M623
  {endif}
  SYNC R0 T120 ; Adjust estimated time

  M106 S0 ; turn off fan , too noisy
  M1002 judge_flag g29_before_print_flag
  M622 J1
    M1002 gcode_claim_action : 1
    {if hold_chamber_temp_for_flat_print && (bed_temperature_initial_layer_single == 55)}
      G29 R
    {else}
      {if (bed_temperature_initial_layer_single > 35)}
        G29 A1 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} I{first_layer_print_size[0]} J{first_layer_print_size[1]} O1 R
      {else}
        G29 A1 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} I{first_layer_print_size[0]} J{first_layer_print_size[1]} O R
      {endif}
    {endif}
    M400
  M623

  M622 J2
    M1002 gcode_claim_action : 1
    {if hold_chamber_temp_for_flat_print && (bed_temperature_initial_layer_single == 55)}
      G29 R
    {else}
      {if (bed_temperature_initial_layer_single > 35)}
        G29 A2 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} I{first_layer_print_size[0]} J{first_layer_print_size[1]} O1 R
      {else}
        G29 A2 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} I{first_layer_print_size[0]} J{first_layer_print_size[1]} O R
      {endif}
    {endif}
    M400
  M623

  M622 J0
    G28 R
  M623
  G29.2 S1
;===== bed leveling end ================================

  M985.1 U0 E2
  M985.1 U1 E2

  M104 S{nozzle_temperature_initial_layer[initial_filament_id]} A
  G150.3 ; move to garbage can to wait for temp

;===== wait temperature reaching the reference value =======
  {if hold_chamber_temp_for_flat_print && (bed_temperature_initial_layer_single == 55)}
    M190 S65
  {else}
    M190 S[bed_temperature_initial_layer_single] ; ensure bed temp
  {endif}

  ;========turn off light and fans =============
  M960 S1 P0 ; turn off laser
  M960 S2 P0 ; turn off laser
  M106 S0 ; turn off cooling fan

;===== wait temperature reaching the reference value =======

  M1002 gcode_claim_action : 255
  M400
  M975 S1 ; turn on mech mode supression

;===== for Textured PEI Plate , lower the nozzle as the nozzle was touching topmost of the texture when homing ==
  {if curr_bed_type=="Textured PEI Plate"}
    {if hold_chamber_temp_for_flat_print && (bed_temperature_initial_layer_single == 55)}
      G29.1 Z{-0.03} ; for Textured PEI Plate first layer
    {else}
      G29.1 Z{-0.04} ; for Textured PEI Plate
    {endif}
  {else}
    G29.1 Z{-0.01}
  {endif}

;===== nozzle load line ===============================
M1002 gcode_claim_action : 51
  G29.2 S1 ; ensure z comp turn on
  G90
  M83
  M400 P50
  M500 D1
  M400 S3
  M109 S{nozzle_temperature_initial_layer[initial_no_support_filament_id]}
  G0 X145 Y0 F24000
  M400
  G130 O0 X145 Y-0.2 Z0.8 F{filament_max_volumetric_speed[initial_no_support_filament_id]/2/2.4053} L40 E20 D4
  G90
  M83
  G1 Z0.2
  M400
;===== nozzle load line end ===========================
M1007 S1 C1;turn on mass estimation && clear
M1002 gcode_claim_action : 0
  G29.99

{if (filament_type[initial_no_support_filament_id] == "TPU")}
M1015.3 S1 H{nozzle_diameter_at_nozzle_id[initial_nozzle_id]};enable tpu clog detect
{else}
M1015.3 S0;disable tpu clog detect
{endif}

{if (filament_type[initial_no_support_filament_id] == "PLA") ||  (filament_type[initial_no_support_filament_id] == "PETG")
 ||  (filament_type[initial_no_support_filament_id] == "PLA-CF")  ||  (filament_type[initial_no_support_filament_id] == "PETG-CF")}
M1015.4 S1 K1 H{nozzle_diameter_at_nozzle_id[initial_nozzle_id]} ;enable E air printing detect
{else}
M1015.4 S0 K0 H{nozzle_diameter_at_nozzle_id[initial_nozzle_id]} ;disable E air printing detect
{endif}

M620.6 I[initial_no_support_filament_id] W1 ;enable ams air printing detect

M1010 Q0 B0.005 S0.01
M1010 Q1 B0.002 S0.01
M1010.1 S1
