;======== P2S layer_change gcode ==========
;===== 2026/05/15 ====

{if (layer_num + 1 == 1)}
{if (overall_chamber_temperature >= 40)}
    ;not reset filter fan in first layer
    ;not reset fan
{else}
{if (min_vitrification_temperature > 50)}
    ;not reset filter fan in first layer
    ;not reset fan
{endif}
{endif}
{endif}

{if (layer_num + 1 <= close_additional_fan_first_x_layers[current_filament_id])}
{if (overall_chamber_temperature < 40)}
    {if (min_vitrification_temperature <= 50)}
        M106 P2 S{first_x_layer_fan_speed[current_filament_id]*255.0/100.0}
    {endif}
{endif}
    M622.1 S0
    M1002 judge_flag ventobox_replace_aux1_fan_flag
    M622 J0
    M106 P10 S{first_x_layer_fan_speed[current_filament_id]*255.0/100.0}; set first x_layer left aux fan
    M623
;not reset fan
{elsif (layer_num + 1 < additional_fan_full_speed_layer[current_filament_id] && additional_fan_full_speed_layer[current_filament_id] > close_additional_fan_first_x_layers[current_filament_id])}
{if (overall_chamber_temperature < 40)}
    {if (min_vitrification_temperature <= 50)}
        M106 P2 S{(first_x_layer_fan_speed[current_filament_id] + (additional_cooling_fan_speed[current_filament_id] - first_x_layer_fan_speed[current_filament_id]) * (layer_num + 1 - close_additional_fan_first_x_layers[current_filament_id]) / max(additional_fan_full_speed_layer[current_filament_id] - close_additional_fan_first_x_layers[current_filament_id], 1)) * 255.0/100.0}
    {endif}
{endif}
    M622.1 S0
    M1002 judge_flag ventobox_replace_aux1_fan_flag
    M622 J0
    M106 P10 S{(first_x_layer_fan_speed[current_filament_id] + (additional_cooling_fan_speed[current_filament_id] - first_x_layer_fan_speed[current_filament_id]) * (layer_num + 1 - close_additional_fan_first_x_layers[current_filament_id]) / max(additional_fan_full_speed_layer[current_filament_id] - close_additional_fan_first_x_layers[current_filament_id], 1)) * 255.0/100.0}
    M623
;not reset fan
{elsif (layer_num + 1 == max(close_additional_fan_first_x_layers[current_filament_id] + 1, additional_fan_full_speed_layer[current_filament_id]))}
{if (overall_chamber_temperature < 40)}
    ;updata chamber autocooling in Xth layer
    {if (min_vitrification_temperature <= 50)}
        {if (nozzle_diameter_at_nozzle_id[current_nozzle_id] == 0.2)}
            M142 P1 R30 S40 U{max_additional_fan/100.0} V1.0 O45; set PLA/TPU ND0.2 chamber autocooling
        {else}
            M142 P1 R30 S40 U{max_additional_fan/100.0} V1.0 O45; set PLA/TPU ND0.4 chamber autocooling
        {endif}
    {else}
            ;not reset filter fan in Xth layer
    {endif}
{else}
        ;not reset filter fan in Xth layer
{endif}
    M622.1 S0
    M1002 judge_flag ventobox_replace_aux1_fan_flag
    M622 J0
    M106 P10 S{additional_cooling_fan_speed[current_filament_id]*255.0/100.0}; set left aux fan
    M623
;not reset fan
{endif}

; update layer progress
M73 L{layer_num+1}
M991 S0 P{layer_num} ;notify layer change

