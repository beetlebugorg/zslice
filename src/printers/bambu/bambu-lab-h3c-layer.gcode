;======== H3C layer_change gcode ==========
;===== 2025/10/16 =====

; update layer progress
M73 L{layer_num+1}
M991 S0 P{layer_num} ;notify layer change
