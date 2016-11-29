`include "defs.sv"

// CPU CLK = VGA CLK / CPU_CLK_DIV
`define CPU_CLK_DIV     20

module top (
    input  clk,
    input  rst,
    input  ps2_clk,
    input  ps2_data,
`ifdef INDICATOR_ENABLED
    output [7:0] seg,
    output [3:0] dig,
    output [3:0] led,
    output beep,
`endif
    output [2:0] rgb,
    output hsync,
    output vsync
);

wire    main_2clk;
reg     main_clk;
reg     cpu_clk;
reg     [31:0] cpu_clk_div;

// -- cpu signals ---
wire    hlt;
reg     int_request;
wire    int_ask;
wire    read_mem;
wire    write_mem;
wire    read_port;
wire    write_port;
wire    [15:0]  addr;
wire    [7:0]   data;

wire    [7:0]   port_addr; assign port_addr = addr[7:0];
reg     [7:0]   port_data;

wire    [13:0]  ram_addr;
wire    [7:0]   ram_r_data;
wire    [7:0]   ram_w_data;

reg     [3:0][3:0] indicator_value;

// -- keyboard --
logic   [7:0]   ps2_recv_data;
logic           ps2_recv_ready;
logic           ps2_key_up_action;
reg     [7:0]   keyboard_key;
typedef bit     [255:0] kk;
kk              keyboard_keys0;
kk              keyboard_keys1;
kk              keyboard_keys;
reg             key_shift;
reg             key_caps;
reg     [7:0]   keyboard_line;


reg     [10:0]  scr_addr;
wire    [10:0]  scr_addr0;
wire    [7:0]   scr_data;
reg     [7:0]   gen_wdata;
reg     [7:0]   scr_wdata;


reg [7:0] debug_line [0:63];

// Адрес на шине попадает в основную память
wire addr_in_main_ram; assign addr_in_main_ram =
        (addr[15:10] == 6'b000000)  ||      // 0000..03ff
        (addr[15:12] == 4'b0011)    ||      // 3000..3fff
        (addr[15:10] == 6'b110000)  ||      // c000..c3ff
        (addr[15:12] == 4'b1110)    ||      // e000..efff
        (addr[15:12] == 4'b1111);           // f000..ffff

// Адрес на шине попадает в адреса индикаторов (9000..93ff)
wire indicator_addr; assign indicator_addr = (addr[15:10] == 6'b100100);

// Адрес на шине попадает в память экрана (e000..efff)
wire addr_in_scr_ram; assign addr_in_scr_ram = (addr[15:12] == 4'b1110);

wire read_main_ram;  assign read_main_ram  = read_mem  && addr_in_main_ram;
wire write_main_ram; assign write_main_ram = write_mem && addr_in_main_ram;
wire read_scr_ram;   assign read_scr_ram   = read_mem  && addr_in_scr_ram;

// Кусочки RAM и ROM соберем в один сплошной диапазон
assign ram_addr =
    addr[15:10] == 6'b000000 ? { 4'b0000, addr[9:0] } :  // 0000..03ff
    addr[15:10] == 6'b110000 ? { 4'b0001, addr[9:0] } :  // c000..c3ff
    addr[15:11] == 5'b00111  ? { 3'b001, addr[10:0] } :  // 3800..3fff
    addr[15:11] == 5'b00110  ? { 3'b110, addr[10:0] } :  // 3000..37ff
    addr[15:12] == 4'b1111   ? { 2'b01,  addr[11:0] } :  // f000..ffff
    addr[15:12] == 4'b1110   ? { 3'b111, addr[10:0] } :  // e000..e7ff (shadow e800..efff)
                                14'h0;

// Запись в screen ram приоритетнее формирования видеосигнала
assign scr_addr0 = write_scr_ram ? addr[10:0] : scr_addr;

// Шина данных
assign data =   int_ask     ?   8'hff :
                read_port   ?   port_data :
                                ram_r_data;


pll_vga (
    .inclk0( clk ),     // 50 Mz
    .c0( main_2clk )    // 63 Mz
);


always @( posedge main_2clk ) main_clk <= ~main_clk;
always @( posedge main_2clk )
begin
    cpu_clk_div <= cpu_clk_div + 1;
    if( cpu_clk_div == `CPU_CLK_DIV )
        begin
            cpu_clk_div <= 0;
            cpu_clk <= ~cpu_clk;
        end
    keyboard_keys <= keyboard_keys1;
    keyboard_keys1 <= keyboard_keys0;
end

// Укоротим сигнал записи в видеопамять до одного тика main_clk чтобы не было "снега"
reg write_scr_ram, last_write_mem;
always @( posedge main_clk )
begin
    last_write_mem <= write_mem;
    write_scr_ram <= (!last_write_mem && write_mem && addr_in_scr_ram);
end


reg one_hz;
reg [31:0] one_hz_count;
always @( posedge main_2clk )
begin
    one_hz_count <= one_hz_count + 1;
    if( one_hz_count ==  63_000_000 )
        begin
            one_hz_count <= 0;
            one_hz <= ~one_hz;
            int_request <= 1;
        end
    if( int_ask ) int_request <= 0;
end


wire ut88_key_shift; assign ut88_key_shift = key_shift;

always @( posedge cpu_clk )
begin

`ifdef INDICATOR_ENABLED
    if( write_mem )
        case( addr )
            16'h9000: indicator_value[1:0] <= ram_w_data;
            16'h9001: indicator_value[3:2] <= ram_w_data;
        endcase
    if( write_port && port_addr == 8'ha1 )
        begin
            beep <= ram_w_data;
        end
`endif

    if( write_port && (port_addr == 8'h07) )
        begin
            keyboard_line <= ram_w_data;
        end;
    if( read_port )
        case( port_addr )
            8'h06:
                begin
                casex( keyboard_line )
                    8'b00000000:
                        port_data <= (|keyboard_keys) ? 8'h00 : 8'h7f;
                    8'bxxxxxxx0:
                        port_data <= ~{
                            1'b1,
                            keyboard_keys['h36],
                            keyboard_keys['h2e],
                            keyboard_keys['h25],
                            keyboard_keys['h26],
                            keyboard_keys['h1e],
                            keyboard_keys['h16],
                            keyboard_keys['h45],
                        };
                    8'bxxxxxx0x:
                        port_data <= ~{
                            1'b1,
                            (key_shift? keyboard_keys['h55] : keyboard_keys['h4e]),
                            keyboard_keys['h41],
                            keyboard_keys['h4c],
                            keyboard_keys['h4c],
                            keyboard_keys['h46],
                            keyboard_keys['h3e],
                            keyboard_keys['h3d],
                        };
                    8'bxxxxx0xx:
                        port_data <= ~{
                            1'b1,
                            (key_caps ? keyboard_keys['h4b] : keyboard_keys['h23]),
                            (key_caps ? keyboard_keys['h1d] : keyboard_keys['h21]),
                            (key_caps ? keyboard_keys['h41] : keyboard_keys['h32]),
                            (key_caps ? keyboard_keys['h2b] : keyboard_keys['h1c]),
                            keyboard_keys['h1e],
                            keyboard_keys['h4a],
                            keyboard_keys['h49],
                        };
                    8'bxxxx0xxx:
                        port_data <= ~{
                            1'b1,
                            keyboard_keys['h42],
                            keyboard_keys['h3b],
                            keyboard_keys['h43],
                            keyboard_keys['h33],
                            keyboard_keys['h34],
                            keyboard_keys['h2b],
                            keyboard_keys['h24],
                        };
                    8'bxxx0xxxx:
                        port_data <= ~{
                            1'b1,
                            keyboard_keys['h2d],
                            keyboard_keys['h15],
                            keyboard_keys['h4d],
                            keyboard_keys['h44],
                            keyboard_keys['h31],
                            keyboard_keys['h3a],
                            keyboard_keys['h4b],
                        };
                    8'bxx0xxxxx:
                        port_data <= ~{
                            1'b1,
                            keyboard_keys['h35],
                            keyboard_keys['h22],
                            keyboard_keys['h1d],
                            keyboard_keys['h2a],
                            keyboard_keys['h3c],
                            keyboard_keys['h2c],
                            keyboard_keys['h1b],
                        };
                    8'bx0xxxxxx:
                        port_data <= ~{
                            1'b1,
                            keyboard_keys['h29],
                            keyboard_keys['h71],
                            keyboard_keys['h70],
                            keyboard_keys['h5b],
                            keyboard_keys['h5d],
                            keyboard_keys['h54],
                            keyboard_keys['h1a],
                        };
                    8'b0xxxxxxx:
                        port_data <= ~{
                            1'b1,
                            keyboard_keys['h6c],
                            keyboard_keys['h77],
                            keyboard_keys['h5a],
                            keyboard_keys['h72],
                            keyboard_keys['h75],
                            keyboard_keys['h6b],
                            keyboard_keys['h74],
                        };
                    default:
                        port_data <= 8'h7f;
                endcase
                end
            8'h05:      port_data <= ~{
                            1'b1,
                            1'b0,
                            1'b0,
                            1'b0,
                            1'b0,
                            ut88_key_shift,
                            1'b0,
                            key_caps,
                        };
            8'ha0:      port_data <= keyboard_key;
            default:    port_data <= 8'h7f;
        endcase
end


`ifdef INDICATOR_ENABLED
Indicator (
    .clk                ( main_clk          ),
    .show_value         ( indicator_value   ),
    .seg                ( seg               ),
    .dig                ( dig               )
);
`endif

i8080cpu (
`ifdef DEBUG
    .debug_line         ( debug_line        ),
`endif
    .clk                ( cpu_clk           ),
    .reset              ( rst               ),
    .hlt                ( hlt               ),
    .addr               ( addr              ),
    .read_mem           ( read_mem          ),
    .write_mem          ( write_mem         ),
    .read_port          ( read_port         ),
    .write_port         ( write_port        ),
    .data               ( data              ),
    .w_data             ( ram_w_data        ),
    .int_request        ( int_request       ),
    .int_ask            ( int_ask           )
);

ram (
    .address            ( ram_addr          ),
    .clock              ( cpu_clk           ),
    .data               ( ram_w_data        ),
    .rden               ( 1                 ),
    .wren               ( write_main_ram    ),
    .q                  ( ram_r_data        )
);

scr_ram (
    .address            ( scr_addr0         ),
    .clock              ( main_clk          ),
    .data               ( ram_w_data        ),
    .rden               ( 1                 ),
    .wren               ( write_scr_ram     ),
    .q                  ( scr_data          )
);



PS2_Controller ( 
  .CLOCK_50             ( clk               ),
  .reset                ( 0                 ),

  .PS2_CLK              ( ps2_clk           ),
  .PS2_DAT              ( ps2_data          ),

  .received_data        ( ps2_recv_data     ),
  .received_data_en     ( ps2_recv_ready    )
);


display (
    .debug_line         ( debug_line        ),
    .clk                ( main_clk          ),
    .scr_data           ( scr_data          ),
    .scr_addr           ( scr_addr          ),
    .hsync              ( hsync             ),
    .vsync              ( vsync             ),
    .rgb                ( rgb               )
);


always @(posedge ps2_recv_ready)
begin
    if( ps2_recv_data == 8'hF0 )
        begin
            ps2_key_up_action <= 1;
        end
    else
        begin
            ps2_key_up_action <= 0;
            if( ps2_key_up_action )
                case( ps2_recv_data )
                    8'h59,
                    8'h12:      key_shift <= 0;
                    default:    keyboard_keys0 <= keyboard_keys & ~(1'b1 << ps2_recv_data);
                endcase
            else
                case( ps2_recv_data )
                    8'h59,
                    8'h12:      key_shift <= 1;
                    8'h58:      key_caps <= ~key_caps;
                    default:    keyboard_keys0 <= keyboard_keys | (1'b1 << ps2_recv_data);
                endcase
                case( ps2_recv_data )
                    8'h45: keyboard_key <= 8'h10;
                    8'h16: keyboard_key <= 8'h01;
                    8'h1e: keyboard_key <= 8'h02;
                    8'h26: keyboard_key <= 8'h03;
                    8'h25: keyboard_key <= 8'h04;
                    8'h2e: keyboard_key <= 8'h05;
                    8'h36: keyboard_key <= 8'h06;
                    8'h3d: keyboard_key <= 8'h07;
                    8'h3e: keyboard_key <= 8'h08;
                    8'h46: keyboard_key <= 8'h09;
                    8'h1c: keyboard_key <= 8'h0a;
                    8'h32: keyboard_key <= 8'h0b;
                    8'h21: keyboard_key <= 8'h0c;
                    8'h23: keyboard_key <= 8'h0d;
                    8'h24: keyboard_key <= 8'h0e;
                    8'h2b: keyboard_key <= 8'h0f;
                    8'h76: keyboard_key <= 8'h80;
                    default: keyboard_key <= 0;
                endcase
        end
end

endmodule
