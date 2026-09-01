create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]
create_clock -name lcd_clk_35 -period 28.571 -waveform {0 14.2855} [get_nets {lcd_clk_d}]