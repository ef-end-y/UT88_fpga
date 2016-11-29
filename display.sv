`include "defs.sv"

module display (
    input   [7:0]   debug_line [0:63],
    input           clk,
    input   [7:0]   scr_data,
    output  [10:0]  scr_addr,
    output          hsync,
    output          vsync,
    output  [2:0]   rgb
);

reg  [9:0]  gen_addr;
reg  [5:0]  gen_data0;
wire [5:0]  gen_data;

wire    rgb_enable;
wire    [11:0] x;
wire    [11:0] y;

reg     [2:0] cur_rgb;
assign rgb = rgb_enable? cur_rgb : 3'b000;

wire [7:0] scr_data0;
`ifdef DEBUG
    assign scr_data0 = scr_addr < 63 ? debug_line[scr_addr]: scr_data;
`else
    assign scr_data0 = scr_data;
`endif

vga_time_generator (
    .clk                ( clk           ),
    .reset_n            ( 1             ),
    .h_disp             ( `H_DISP       ),
    .h_fporch           ( `H_FPORCH     ),
    .h_sync             ( `H_SYNC       ),
    .h_bporch           ( `H_BPORCH     ),

    .v_disp             ( `V_DISP       ),
    .v_fporch           ( `V_FPORCH     ),
    .v_sync             ( `V_SYNC       ),
    .v_bporch           ( `V_BPORCH     ),
    .hs_polarity        ( 1'b1          ),
    .vs_polarity        ( 1'b1          ),
    .frame_interlaced   ( 1'b0          ),

    .vga_hs             ( hsync         ),
    .vga_vs             ( vsync         ),
    .vga_de             ( rgb_enable    ),
    .pixel_x            ( x             ),
    .pixel_y            ( y             )
);

gen_ram (
    .address            ( gen_addr      ),
    .clock              ( clk           ),
    .data               ( gen_wdata     ),
    .wren               ( 0             ),
    .q                  ( gen_data      )
);

wire last_x_char; assign last_x_char = x >= (`UT88_MAX_X - 5);
wire [2:0] next_y; assign next_y = (y + (last_x_char ? 1 : 0)) & 3'b111;

reg is_cursor;
reg  [3:0]  scr_bit_pos;

always @( posedge clk )
begin
    cur_rgb <=  (x > `UT88_MAX_X) || (y > `UT88_MAX_Y) ? 3'b000 :
                (gen_data0 >> (5 - scr_bit_pos)) & 1'b1 ? 3'b111 : 3'b000;
    if( y == (`UT88_MAX_Y + 1) )
        begin
            case( x )
                0:  begin
                        scr_addr    <= 0;
                        scr_bit_pos <= 0;
                    end
                2:  begin
                        gen_addr    <= (scr_data0[6:0] << 3);
                        is_cursor   <= scr_data0[7];
                    end
                4:  gen_data0   <= gen_data;    
            endcase
        end
    else if( (y <= `UT88_MAX_Y) && (x <= `UT88_MAX_X) )
        begin
            case( scr_bit_pos )
                0:  scr_addr        <= last_x_char && (y[2:0] != 3'b111) ? scr_addr - 10'd63 : scr_addr + 10'd1;
                2:  begin
                        is_cursor   <= scr_data0[7];
                        gen_addr    <= (scr_data0[6:0] << 3) + next_y;
                    end
                5:  gen_data0       <= is_cursor ? ~gen_data : gen_data;
            endcase
            scr_bit_pos <= (scr_bit_pos==5)? 0 : scr_bit_pos + 1;
        end
end

endmodule