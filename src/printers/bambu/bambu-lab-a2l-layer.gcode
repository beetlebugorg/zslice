;======== A2L layer_change gcode ==========
;===== 2026/04/29 ====
; update layer progress
M201 N1 Y[curr_y_acceleration_limit]
M73 L{layer_num+1}
M991 S0 P{layer_num} ;notify layer change
M1007 L1