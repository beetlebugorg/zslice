;===== machine: H3C start ======
;===== date: 20261102 =====================
M104 S0 G
M630 S0 P0
M630 S1 P0

M400

;=====printer start sound ===================
M17
M400 S1
M1006 S1
M1006 A53 B9 L50 C53 D9 M99 E53 F9 N99 
M1006 A56 B9 L90 C56 D9 M99 E56 F9 N99 
M1006 A61 B9 L99 C61 D9 M99 E61 F9 N99 
M1006 A53 B9 L99 C53 D9 M99 E53 F9 N99 
M1006 A56 B9 L99 C56 D9 M99 E56 F9 N99 
M1006 A61 B18 L60 C61 D18 M80 E61 F18 N80
M1006 W
;=====printer start sound ===================

;===== reset machine status =================
M204 S10000
M630 S0 P0;close shell detect
M630 S1 P0;close cutter detect

G90
M17 D ; reset motor current to default
G90
M220 S100 ;Reset Feedrate
M221 S100 ;Reset Flowrate
M73.2   R1.0 ;Reset left time magnitude
G29.1 Z{+0.0} ; clear z-trim value first
M983.1 M1 ; Set nonlinear extrusion compensation
M901 D4 ; Set the advance amount for the E-axis
M481 S0 ; turn off cutter pos comp
G28.140 D0; reset pre-extrude z pos
M9714 A0
;===== reset machine status =================

M620.29 P ; print nozzle info
M620 M ; enable remap
M620 T0
M650.5 P1
M650.5 W L20 F600
M650.8 C1 ; Enable hotend detachment detection
M650.11 E0

{if (enable_prime_tower)}
    M620.35 S1
{else}
    M620.35 S0
{endif}

;===== avoid end stop =================
G91
G380 S2 Z27 F1200
G380 S2 Z-12 F1200
G90
;===== avoid end stop =================

;===== first XY & holder homing start =====
M1002 gcode_claim_action : 13
M650.4 H F
G28 X T300
;===== first XY & holder homing end =====

;===== break hall sensor selfcheck start =====
G34 M4		;printf brake hall sensor info
G34 M6 F84000 D1	;break hall sensor selfcheck
G34 K1		;turn on sensor_lost_step_detect sub switch
G34 M4		;printf brake hall sensor info

M1001 S46 P12	;TH E1M cog_cali_info print
;===== break hall sensor selfcheck end =====

M400
;====== cog noise reduction=================
M982.2 S1 ; turn on cog noise reduction

;===== first Z homing start =====
M1002 gcode_claim_action : 74 ; Heatbed surface foreign object detection

M650.1 S[initial_no_support_filament_id]

G150.1 F8000 ; wipe mouth to avoid filament stick to heatbed
G150.3 F8000
M400 P200

M972 S24 P0 T30000 ; liveview camera detect
M972 S26 P0 C0 ; Heatbed surface foreign object detection
M972 S41 P0

M1009 Q1 L1
G90
G150.1
G1 X165 Y160 F30000
G28 Z P0 T250 U1
M1009 Q1 L0

G90

;===== first Z homing end =====
M1002 judge_flag build_plate_detect_flag
M622 S1
    ;M1002 gcode_claim_action : 11 ; Indentifying build plate type
    G1 X165 Y160 F30000
    M972 S19 P0 C0    ; heatbed presence detection
M623

;==== set airduct mode ====

{if (overall_chamber_temperature >= 40)}
    M650.1 P ; put nozzle
    M145 P1 ; set airduct mode to heating mode for heating
    M106 P2 S0 ; turn off auxiliary fan
    M106 P10 S0 ; turn off auxiliary fan1
    M106 P3 S0 ; turn off chamber fan
    M106 P15 S0 ; turn on chamber1 fan

{else}
    M145 P0 ; set airduct mode to cooling mode for cooling
    M106 P2 S178 ; turn on auxiliary fan for cooling
    M106 P10 S178 ; turn on auxiliary fan1 for cooling
    M106 P3 S178 ; turn on chamber fan for cooling
    M106 P15 S178 ; turn off chamber1 fan
    M140 S0 ; stop heatbed from heating

    M1002 gcode_claim_action : 29
    M191 S0 ; wait for chamber temp
    M106 P2 S0 ; turn off auxiliary fan
    M106 P10 S0 ; turn off auxiliary fan1
    {if (min_vitrification_temperature <= 50)}
        {if (nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id] == 0.2)}
            M142 P1 R30 S38 T40 U0.3 V0.75 W1.0 O45 ; set PLA/TPU ND0.2 chamber autocooling
            M142 P6 R30 S38 T41 U0.3 V0.6 W1.0     ; set PLA/TPU ND0.2 chamber1 autocooling
        {else}
            M142 P1 R30 S38 T40 U0.3 V0.75 W1.0 O45; set PLA/TPU ND0.4 chamber autocooling
            M142 P6 R30 S38 T41 U0.3 V0.6 W1.0    ; set PLA/TPU ND0.4 chamber1 autocooling
        {endif}
    {else}
        {if (nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id] == 0.2)}
            M142 P1 R35 S45 T50 U0.3 V0.75 W1.0 O50 L1 ; set PETG ND0.2 chamber autocooling
            M142 P6 R35 S45 T50 U0.3 V0.6 W1.0        ; set PETG ND0.2 chamber1 autocooling
        {else}
            M142 P1 R35 S45 T50 U0.3 V0.75 W1.0 O55 L1 ; set PETG ND0.4 chamber autocooling
            M142 P6 R35 S45 T50 U0.3 V0.6 W1.0        ; set PETG ND0.4 chamber1 autocooling
        {endif}
    {endif}
{endif}
M142.1 P8 Q1;enable ac autocooling
;==== set airduct mode ====

;====== preheat heated bed in advance =========
M1002 gcode_claim_action : 2
M140 S[bed_temperature_initial_layer_single]
;====== set chamber temperature ============
{if (overall_chamber_temperature >= 40)}
    M141 S[overall_chamber_temperature] ; Let Chamber begin to heat
{endif}

M650.6 ; Nozzle Pick-and-Place Inspection
M650.1 S[initial_no_support_filament_id]

M400

M1002 judge_flag build_plate_detect_flag
M622 S1
    G1 X165 Y160 F30000
    M106 P1 S0
    M18 E
    M400 P200
    M1028 S1

    M972 S31 P0 T5000 ; toolhead camera dirty detection
    M972 S34 P0 T5000 ; heatbed plate offset detection
    M972 S30 P0 T30000 ; birdeye camera foolproof
    M1028 S0
    M17 D
M623

;===== detection start =====
M1002 gcode_claim_action : 72 ; Hotend Type Detection
M651 S0 ; nozzle type detection
M650.1 S[initial_no_support_filament_id]

M104 S{nozzle_temperature_initial_layer[initial_no_support_filament_id]-80} A L2; rise temp in advance
M104 I[initial_no_support_filament_id] S{nozzle_temperature_initial_layer[initial_no_support_filament_id]-80}

G150.3
G90
G1 Z3 F1200
M400
M650.4 H F
G1 Z10 F1200
M400
G150.3
{if max_print_z >= 145}
    M1002 gcode_claim_action : 75 ;  Detect obstacles at the botton of the heated bed
    M104 S{nozzle_temperature_initial_layer[initial_no_support_filament_id]} ; rise temp in advance
    G3811 Z{max_print_z}  ; Detect obstacles at the bottom of the heated bed
{endif}

;===== detection end =====

M400

;===== get hotend map start=====
M620 T3
;===== get hotend map end=====

;===== prepare print temperature and material ==========
M211 X0 Y0 Z0 ;turn off soft endstop
M975 S1 ; turn on input shaping

G29.2 S0 ; avoid invalid abl data

{if ((filament_type[initial_no_support_filament_id] == "PLA") || (filament_type[initial_no_support_filament_id] == "PLA-CF") || (filament_type[initial_no_support_filament_id] == "PETG")) && (nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id] == 0.2)}
M620.10 A0 F74.8347 H{nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id]} T{flush_temperatures[initial_no_support_filament_id]} P{nozzle_temperature_initial_layer[initial_no_support_filament_id]} S1
M620.10 A1 F74.8347 H{nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id]} T{flush_temperatures[initial_no_support_filament_id]} P{nozzle_temperature_initial_layer[initial_no_support_filament_id]} S1 V{filament_max_volumetric_speed[initial_no_support_filament_id]/(filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]*3.14159/4)}
{else}
M620.10 A0 F{flush_volumetric_speeds[initial_no_support_filament_id]/(filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]*3.14159/4)*60} H{nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id]} T{flush_temperatures[initial_no_support_filament_id]} P{nozzle_temperature_initial_layer[initial_no_support_filament_id]} S1
M620.10 A1 F{flush_volumetric_speeds[initial_no_support_filament_id]/(filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]*3.14159/4)*60} H{nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id]} T{flush_temperatures[initial_no_support_filament_id]} P{nozzle_temperature_initial_layer[initial_no_support_filament_id]} S1 V{filament_max_volumetric_speed[initial_no_support_filament_id]/(filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]*3.14159/4)}
{endif}

M620.11 P0 I[initial_no_support_filament_id] E0

{if long_retraction_when_ec }
M620.11 K1 I[initial_no_support_filament_id] R{retraction_distance_when_ec} F{max((flush_volumetric_speeds[initial_no_support_filament_id]/(filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]*3.14159/4)*60), 200)}
{else}
M620.11 K0 I[initial_no_support_filament_id] R0
{endif}

{if (fins_extrude_safe_temp[initial_no_support_filament_id]) < 30}
M650.11 E0
{else}
M650.11 E1
M650.11 A{fins_extrude_safe_temp[initial_no_support_filament_id]} B{fins_extrude_safe_temp[initial_no_support_filament_id] - 5}
{endif}

M650.8 C2
M620 S[initial_no_support_filament_id]A   ; switch material if AMS exist
M1002 gcode_claim_action : 4
M1002 set_filament_type:UNKNOWN
M1002 set_next_filament_id:{filament_ids[initial_no_support_filament_id]}
M400
T[initial_no_support_filament_id]
M400
M628 S0
M629

M400
M1002 set_filament_type:{filament_type[initial_no_support_filament_id]}
M621 S[initial_no_support_filament_id]A
M650.8 C1

M104 S{nozzle_temperature_initial_layer[initial_no_support_filament_id]}
M400
M106 P1 S0

G29.2 S1
;===== prepare print temperature and material ==========

M1002 set_filament_type:{filament_type[initial_no_support_filament_id]}
;===== auto extrude cali start =========================
  M1002 judge_flag extrude_cali_flag
  M622 J0

    M983.3 F{filament_max_volumetric_speed[initial_no_support_filament_id]/2.4} A{nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id]} ; cali dynamic extrusion compensation
  M623

  M622 J1
    M1002 set_filament_type:{filament_type[initial_no_support_filament_id]}
    M1002 gcode_claim_action : 8
    M109 S{nozzle_temperature[initial_no_support_filament_id]}
    G90
    M83
    M983.3 F{filament_max_volumetric_speed[initial_no_support_filament_id]/2.4} A{nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id]} ; cali dynamic extrusion compensation
    M400
    M106 P1 S255
    M400 S5
    M106 P1 S0
    G150.3
  M623

  M622 J2
    M1002 set_filament_type:{filament_type[initial_no_support_filament_id]}
    M1002 gcode_claim_action : 8
    M109 S{nozzle_temperature[initial_no_support_filament_id]}
    G90
    M83
    M983.3 F{filament_max_volumetric_speed[initial_no_support_filament_id]/2.4} A{nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id]} ; cali dynamic extrusion compensation
    M400
    M106 P1 S255
    M400 S5
    M106 P1 S0
    G150.3
  M623
;===== auto extrude cali end =========================
M650.11 E0
G150.1
M400

G387 Y295 J1 F60000
M400
G387 Y265 J1 F18000
M400

;===== wipe nozzle start =====
M1002 gcode_claim_action : 14
G150 T{nozzle_temperature_initial_layer[initial_no_support_filament_id]} U1
{if (overall_chamber_temperature >= 40)}
    G150 T{nozzle_temperature_initial_layer[initial_no_support_filament_id] - 80} U1
{endif}

M106 S255 ; turn on fan to cool the nozzle
M109 S140
M400 S5
G91
G1 Z5 F1200
G90
M106 S0 ; turn off fan
;===== wipe nozzle end =====

G387 Y295 J1 F60000
M400
G387 Y265 J1 F18000
M400

;===== mech mode sweep start =====
M1002 gcode_claim_action : 3
G90
G0 X165 Y160 Z5 F10000
M400 P200

M970.3 Q0 A8 K0 O1
M970.2 Q0 K1 W87 Z0.10
M970.3 Q1 A5 K0 O1
M970.2 Q1 K1 W81 Z0.12
M970.2 Q2 K0 W36 Z0.01
M970.2 Q2 K1 W76 Z0.10
M974 S2 P0

M975 S1
M400
;===== mech mode sweep end =====


;===== pre-check for toolhead cali ====================
M1002 judge_flag auto_cali_toolhead_offset_flag
M622 J2
    G37.3;
M623

;===== extra wait for thermal deformation =============
G90
G1 X165 Y160 F20000
M190 S[bed_temperature_initial_layer_single]

M1002 set_flag auto_detect_heatbed_type_flag=1
M1002 judge_flag auto_detect_heatbed_type_flag
{if (overall_chamber_temperature >= 40)}
    M1002 gcode_claim_action : 49
    M191 S[overall_chamber_temperature] ; wait for chamber temp
    M1002 judge_flag bed_heat_stable_wait_flag
    M622 J1
        M1002 gcode_claim_action : 63
        M1030 S600 ; Waiting for the Chamber temperature to equalize
        SYNC R0 T600
        M1030 C
    M623
{else}
    M1002 judge_flag bed_heat_stable_wait_flag
    M622 J1
        M1002 gcode_claim_action : 82
        {if bed_temperature_initial_layer_single > 89}
            M1030 S600 ; Waiting for temperature to equalize
            SYNC R0 T600
            M1030 C
        {else}
            M1030 S120 ; Waiting for temperature to equalize
            SYNC R0 T120
            M1030 C
        {endif}
    M623
{endif}

;===== xy ofst cali start =====
M1002 judge_flag auto_cali_toolhead_offset_flag
M622 J1
    M190 D[bed_temperature_initial_layer_single]
    M1002 gcode_claim_action : 39
    M650.8 C2
    G37 O2 M2 T140 U140 H{nozzle_temperature_initial_layer[initial_no_support_filament_id]-40} Q1
    M650.8 C1
M623

M622 J2
    M190 D[bed_temperature_initial_layer_single]
    M1002 gcode_claim_action : 39
    M650.8 C2
    G37 J1 O2 M2 T140 U140 H{nozzle_temperature_initial_layer[initial_no_support_filament_id]-40} Q1
    M650.8 C1
M623

G37.6
;===== xy ofst cali end =====

M400

;===== bed leveling ==================================
M190 S[bed_temperature_initial_layer_single]; ensure bed temp
M109 S140
M650.1 A7 ; retake nozzle
M106 S0 ; turn off fan , too noisy

G91
G1 Z5 F1200
G90
G1 X165 Y160 F30000

M1002 judge_flag g29_before_print_flag
M622 J1
    M1002 gcode_claim_action : 1
    G29.20 A3
    G29 A1 U1 O X{first_layer_print_min[0]} Y{first_layer_print_min[1]} I{first_layer_print_size[0]} J{first_layer_print_size[1]} R
    M400
M623

M622 J2
    M1002 gcode_claim_action : 1
    {if has_tpu_in_first_layer}
        G29.20 A3
        G29 A1 U1 O X{first_layer_print_min[0]} Y{first_layer_print_min[1]} I{first_layer_print_size[0]} J{first_layer_print_size[1]} R
    {else}
        G29.20 A4
        G29 A2 U1 O X{first_layer_print_min[0]} Y{first_layer_print_min[1]} I{first_layer_print_size[0]} J{first_layer_print_size[1]} R
    {endif}
    M400
M623

M622 J0
    G28 X R
    G150.1
    G1 X165 Y160 F18000
    G28 Z U1
M623

;===== bed leveling end ================================
G90
G1 Z5 F1200
G1 X270 Y-0.5 F60000
G28.140 S0 ; cali pre-extrude z pos
G1 Z5 F1200

M400

G150.3 ; move to garbage can to wait for temp
M1026

M400

;============switch again==================
M620 O1
M211 X0 Y0 Z0 ;turn off soft endstop
G91
G1 Z6 F1200
G90
M1002 set_filament_type:{filament_type[initial_no_support_filament_id]}
{if (fins_extrude_safe_temp[initial_no_support_filament_id]) < 30}
M650.11 E0
{else}
M650.11 E1
M650.11 A{fins_extrude_safe_temp[initial_no_support_filament_id]} B{fins_extrude_safe_temp[initial_no_support_filament_id] - 5}
{endif}
M650.8 C2
M620 S[initial_no_support_filament_id]A
M400
T[initial_no_support_filament_id]
M400
M628 S0
M629
M400
M621 S[initial_no_support_filament_id]A
M650.8 C1
;============switch again==================

M400

;===== wait temperature reaching the reference value =======
M104 S0 A; rise prepare temp in advance
M104 S{nozzle_temperature_initial_layer[initial_no_support_filament_id]} ; rise to print tmpr

M140 S[bed_temperature_initial_layer_single]
M190 S[bed_temperature_initial_layer_single]

    ;========turn off light and fans =============
    M960 S1 P0 ; turn off laser
    M960 S2 P0 ; turn off laser
    M106 S0 ; turn off fan
    M106 P2 S0 ; turn off auxiliary fan
    M106 P10 S0 ; turn off auxiliary fan1

    ;============set motor current==================
    M400 S1

;===== wait temperature reaching the reference value =======

;===== for Textured PEI Plate , lower the nozzle as the nozzle was touching topmost of the texture when homing ==
    {if curr_bed_type=="Textured PEI Plate"}
        {if nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id] == 0.2}
            {if ((filament_type[initial_no_support_filament_id] == "PA-CF") || (filament_type[initial_no_support_filament_id] == "PA6-CF") || (filament_type[initial_no_support_filament_id] == "PPA-CF"))}
                G29.1 Z{0.04} ; for Textured PEI Plate
            {else}
                {if ((filament_type[initial_no_support_filament_id] == "PET-CF") || (filament_type[initial_no_support_filament_id] == "PA-GF"))}
                    G29.1 Z{0.01} ; for Textured PEI Plate
                {else}
                    G29.1 Z{0.00} ; for Textured PEI Plate
                {endif}
            {endif}
        {else}
            {if ((filament_type[initial_no_support_filament_id] == "PA-CF") || (filament_type[initial_no_support_filament_id] == "PA6-CF") || (filament_type[initial_no_support_filament_id] == "PPA-CF"))}
                G29.1 Z{0.03} ; for Textured PEI Plate
            {else}
                {if ((filament_type[initial_no_support_filament_id] == "PET-CF") || (filament_type[initial_no_support_filament_id] == "PA-GF"))}
                    G29.1 Z{0.00} ; for Textured PEI Plate
                {else}
                    G29.1 Z{-0.02} ; for Textured PEI Plate
                {endif}
            {endif}
        {endif}
    {else}
        {if nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id] == 0.2}
            {if ((filament_type[initial_no_support_filament_id] == "PA-CF") || (filament_type[initial_no_support_filament_id] == "PA6-CF") || (filament_type[initial_no_support_filament_id] == "PPA-CF"))}
                G29.1 Z{0.04} ; for Textured PEI Plate
            {else}
                {if ((filament_type[initial_no_support_filament_id] == "PET-CF") || (filament_type[initial_no_support_filament_id] == "PA-GF"))}
                    G29.1 Z{0.01} ; for Textured PEI Plate
                {else}
                    G29.1 Z{0.01} ; for Textured PEI Plate
                {endif}
            {endif}
        {else}
            {if ((filament_type[initial_no_support_filament_id] == "PA-CF") || (filament_type[initial_no_support_filament_id] == "PA6-CF") || (filament_type[initial_no_support_filament_id] == "PPA-CF"))}
                G29.1 Z{0.04} ; for Textured PEI Plate
            {else}
                {if ((filament_type[initial_no_support_filament_id] == "PET-CF") || (filament_type[initial_no_support_filament_id] == "PA-GF"))}
                    G29.1 Z{0.01} ; for Textured PEI Plate
                {else}
                    G29.1 Z{0.00} ; for Textured PEI Plate
                {endif}
            {endif}
        {endif}
    {endif}

G150.1
G150.3

M975 S1 ; turn on mech mode supression
G29.2 S1 ; turn on pos comp

G90
G1 Z5 F1200

{if (filament_ids[initial_no_support_filament_id] == "GFU06")}
M1015.4 L15
M1015.5 S1
{elsif (filament_ids[initial_no_support_filament_id] == "GFU04")}
M1015.4 L15
M17 E0.25
M1015.5 S0
{elsif (filament_ids[initial_no_support_filament_id] == "GFU03")}
M1015.4 L15
M17 E0.4
M1015.5 S0
{else}
M1015.4 L10
M1015.5 S1
{endif}
M620.6 I[initial_no_support_filament_id] H[initial_no_support_hotend] W1 ;enable ams air printing detect

G387 Y295 J1 F60000
G387 Y265 J1 F18000

;===== nozzle load line ===============================
M1002 gcode_claim_action : 51
    G29.2 S1 ; ensure z comp turn on
    G90
    M83
    G1 Z5 F1200
    G1 X270 Y-0.5 F60000
    G28.14 R0
    G29.2 S0
    G91
    G1 Z0.8 F1200
    G90
    G1 X250 F60000
    
    ;========== record data ==========
    M1026
    M1012.8
    M1012.9
    M400 P50
    G29.9
    M400 P50
    G37.2 R
    G37.5
    ;========== record data ==========
    
    M400 P50
    M500 D1
    M400 S3
    M109 S{nozzle_temperature_initial_layer[initial_no_support_filament_id]}
    M83
{if nozzle_diameter_at_nozzle_id[initial_no_support_nozzle_id] == 0.8}
    G1 E5 F{filament_max_volumetric_speed[initial_no_support_filament_id]/(filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]*3.14159/4)*60}
{endif}
{if (filament_type[initial_no_support_filament_id] == "TPU")}
    G1 E{5/((filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]/3.0625))} F{filament_max_volumetric_speed[initial_no_support_filament_id]/(filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]*3.14159/4)*60}
{endif}
    G1 E5 F{filament_max_volumetric_speed[initial_no_support_filament_id]/(filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]*3.14159/4)*60}
    G1 X290 E10 F{filament_max_volumetric_speed[initial_no_support_filament_id]/(filament_diameter[initial_no_support_filament_id]*filament_diameter[initial_no_support_filament_id]*3.14159/4)*60}
    G91
    G3 Z0.4 I1.217 J0 P1 F60000
    G90
    M83
    G29.2 S1 ; ensure z comp turn on
;===== noozle load line end ===========================

M1002 gcode_claim_action : 0

M400
M211 Z1
G29.99
