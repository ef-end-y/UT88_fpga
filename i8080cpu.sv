// Intel 8080 (KR580VM80A) microprocessor
//
// Copyright (C) 2016 Volyk Stanislav <max.begemot@gmail.com>



`timescale 1ns / 1ps

//`define       BIDIRECTIONAL_DATA

// `define get_alu_op(data) data[5:3]
`define get_alu_op(data) alu_ops'(data[5:3])

typedef enum {
    st_start,
    st_run,
    st_idle_clock,
    st_mov_arg2reg,
    st_mov_arg2reg_pair,
    st_mov_mem2reg,
    st_mov_reg2mem,
    st_alures2reg,
    st_alures2mem,
    st_alu_mem_op,
    st_arg2alu,
    st_lhld,
    st_lhld_2,
    st_lhld_3,
    st_lhld_4,
    st_lda1,
    st_lda2,
    st_sta1,
    st_sta2,
    st_shld,
    st_shld_1,
    st_shld_2,
    st_daa,
    st_push,
    st_pop,
    st_jmp,
    st_jmp_now,
    st_call,
    st_call_push_pc_l,
    st_call_push_pc_h,
    st_call_jmp,
    st_rst,
    st_ret,
    st_ret_now,
    st_xthl,
    st_xthl_2,
    st_xthl_3,
    st_out,
    st_in,
    st_in_wait,
    st_in_now
} states;

typedef enum {
    mem_pc,
    mem_pc1,
    mem_pc2,
    mem_read,
    mem_write,
    mem_io_in,
    mem_io_out
} mem_ops;

typedef enum {
    alu_op_add=0,
    alu_op_adc=1,
    alu_op_sub=2,
    alu_op_sbb=3,
    alu_op_and=4,
    alu_op_xor=5,
    alu_op_or=6,
    alu_op_cmp=7,
    alu_op_inr=8,
    alu_op_dcr=9,
    alu_op_none=10
} alu_ops;

typedef enum {
    reg_b=0, // B
    reg_c=1, // C
    reg_d=2, // D
    reg_e=3, // E
    reg_h=4, // H
    reg_l=5, // L
    reg_m=6, // M
    reg_a=7  // A
} reg_num;


function string regname( input int regnum );
    case( regnum )
        0: return "B";
        1: return "C";
        2: return "D";
        3: return "E";
        4: return "H";
        5: return "L";
        6: return "M";
        7: return "A";
        default: return "?";
    endcase
endfunction

function string pairname( input int pairnum );
    case( pairnum )
        0: return "B";
        1: return "D";
        2: return "H";
        3: return "SP";
        default: return "?";
    endcase
endfunction

function string pairname_psw( input int pairnum );
    case( pairnum )
        0: return "B";
        1: return "D";
        2: return "H";
        3: return "PSW";
        default: return "?";
    endcase
endfunction

function string opname( input int opnum );
    case( opnum )
        0: return "ADD";
        1: return "ADC";
        2: return "SUB";
        3: return "SBB";
        4: return "AND";
        5: return "XOR";
        6: return "OR";
        7: return "CMP";
        8: return "INR";
        9: return "DCR";
        default: return "?";
    endcase
endfunction

function string cond_str( input int condnum );
    case( condnum )
        0: return "NZ";
        1: return "Z";
        2: return "NC";
        3: return "C";
        4: return "PO";
        5: return "PE";
        6: return "P";
        7: return "M";
        default: return "?";
    endcase
endfunction

    
module i8080cpu (
`ifdef DEBUG
    output [7:0] debug_line [0:63],
`endif
    input clk,
    input reset,
    input int_request,
    output reg hlt,
    output reg int_ask,
    output wire [15:0] addr,
    output wire read_mem,
    output wire write_mem,
    output wire read_port,
    output wire write_port,
`ifdef BIDIRECTIONAL_DATA
    inout  wire [7:0] data
`else
    input       [7:0] data,
    output wire [7:0] w_data
`endif
);

`ifdef BIDIRECTIONAL_DATA
    reg [7:0] w_data;
`endif

reg [15:0] pc;
reg [15:0] sp;
reg [15:0] mem_addr;

reg [7:0] regs [7:0];

reg [7:0] cmd;
reg [7:0] w_data2;
reg [7:0] jmp_addr;

mem_ops mem_op;

states state;

wire io_op; assign io_op = (mem_op == mem_io_in) || (mem_op == mem_io_out);
assign read_mem   = (mem_op != mem_write) && !io_op && !int_ask ? 1'b1 : 1'b0;
assign write_mem  = (mem_op == mem_write) && !io_op ? 1'b1 : 1'b0;
assign read_port  = (mem_op == mem_io_in)  ? 1'b1 : 1'b0;
assign write_port = (mem_op == mem_io_out) ? 1'b1 : 1'b0;

assign addr = (mem_op == mem_pc)  ? pc           :
              (mem_op == mem_pc1) ? (pc + 16'h1) : 
                                    mem_addr;

`ifdef BIDIRECTIONAL_DATA
    assign data = (mem_op == mem_write) || (mem_op == mem_io_out) ? w_data : 8'bz;
`endif


wire [15:0] regs_hl; assign regs_hl = {regs[reg_h], regs[reg_l]};
wire [15:0] regs_bc; assign regs_bc = {regs[reg_b], regs[reg_c]};
wire [15:0] regs_de; assign regs_de = {regs[reg_d], regs[reg_e]};

reg [2:0] dst_reg;

alu_ops alu_op;
reg [7:0] alu_res;
reg [7:0] alu_a;
reg [7:0] alu_b;
reg flag_z;
reg flag_ac;
reg flag_s;
reg flag_c;
reg flag_p;
reg ie; // interrupt enabled

wire cond_ok; assign cond_ok = 
    (data[5:3] == 3'b000) ? !flag_z :
    (data[5:3] == 3'b001) ?  flag_z :
    (data[5:3] == 3'b010) ? !flag_c :
    (data[5:3] == 3'b011) ?  flag_c :
    (data[5:3] == 3'b100) ? !flag_p :
    (data[5:3] == 3'b101) ?  flag_p :
    (data[5:3] == 3'b110) ? !flag_s :
                             flag_s ;


function [7:0] get_hex( input [3:0] i );
    return i + (i > 9? 55 : 48);
endfunction

                         
always @(posedge clk or negedge reset)
begin
`ifdef DEBUG
    debug_line[0] <= get_hex(pc[15:12]);
    debug_line[1] <= get_hex(pc[11:8]);
    debug_line[2] <= get_hex(pc[7:4]);
    debug_line[3] <= get_hex(pc[3:0]);

    debug_line[10] <= get_hex(sp[15:12]);
    debug_line[11] <= get_hex(sp[11:8]);
    debug_line[12] <= get_hex(sp[7:4]);
    debug_line[13] <= get_hex(sp[3:0]);
`endif

    if( ~reset )
        begin
            $display("RESET");
            state <= st_start;
            ie <= 1;
            pc <= 0;
            sp <= 0;
            hlt <= 0;
            int_ask <= 0;
            mem_op <= mem_pc;
            alu_op <= alu_op_none;
        end
    else if( mem_op == mem_read )
        begin
            $display("      read mem %h", mem_addr);
            mem_op <= mem_pc;
        end
    else if( mem_op == mem_write )
        begin
            $display("      wait 1 tick for mem write");
            mem_op <= mem_pc;
        end
    else if( mem_op == mem_io_out )
        begin
            $display("      wait 1 tick for port write");
            mem_op <= mem_pc;
        end
    else
      begin
      mem_op <= mem_pc;
      alu_op <= alu_op_none;
      int_ask <= 0;
      case( state )
        st_start:
            begin
                if( int_request && ie )
                    begin
                        $display("--- INTERRUPT ---");
                        ie <= 0;
                        int_ask <= 1;
                        hlt <= 0;
                        state <= st_run;
                    end
                else
                    begin
                        if( hlt )
                            begin
                                state <= st_start;
                            end
                        else
                            begin
                                state <= st_run;
                                pc <= pc + 16'h1;
                                $display("%h\t\t\t\t\t\tA: %H  BC: %H  DE: %H  HL: %H  SP: %H  fZ: %H, fC: %H, fS: %h, fAC: %h,  fP: %H",
                                    pc, regs[7], {regs[0], regs[1]}, {regs[2], regs[3]}, {regs[4], regs[5]}, sp, flag_z, flag_c, flag_s, flag_ac, flag_p
                                );
                            end
                    end
            end
        st_run:
            begin
            cmd <= data;
            casex( data )
                8'b01110110:
                    begin
                        $display("      HLT");
                        hlt <= 1;
                        state <= st_start;
                    end
                8'b00xxx110:
                    begin
                        $display("      MVI %s, nn", regname(data[5:3]));
                        dst_reg = data[5:3];
                        state <= st_mov_arg2reg;
                    end
                8'b00xx0001:
                    begin
                        $display("      LXI %s, nnnn", pairname(data[5:4]));
                        dst_reg <= { 1'b0, data[5:4] };
                        mem_op <= mem_pc1;
                        state <= st_mov_arg2reg_pair;
                    end
                8'b000x1010:
                    begin
                        $display("      LDAX %s", (data[4]? "D" : "B"));
                        dst_reg <= reg_a;
                        mem_addr <= data[4]? regs_de : regs_bc;
                        mem_op <= mem_read;
                        state <= st_mov_mem2reg;
                    end
                8'b00111010:
                    begin
                        $display("      LDA");
                        mem_op <= mem_pc1;
                        state <= st_lda1;
                    end
                8'b00101010:
                    begin
                        $display("      LHLD");
                        mem_op <= mem_pc1;
                        state <= st_lhld;
                    end
                8'b00110010:
                    begin
                        $display("      STA");
                        mem_op <= mem_pc1;
                        state <= st_sta1;
                    end
                8'b00100010:
                    begin
                        $display("      SHLD");
                        mem_op <= mem_pc1;
                        state <= st_shld;
                    end
                8'b000x0010:
                    begin
                        $display("      STAX %s", (data[4]? "D" : "B"));
                        w_data <= regs[reg_a];
                        mem_addr <= data[4]? regs_de : regs_bc;
                        mem_op <= mem_write;
                        state <= st_start;
                    end
                8'b00xxx10x:  // DRC / INR
                    begin
                        $display("      %s %s", data[0]? "DCR" : "INR", regname(data[5:3]));
                        if( data[5:3] == reg_m )
                            begin
                                mem_addr <= regs_hl;
                                mem_op <= mem_read;
                                state <= st_alures2mem;
                            end
                        else
                            begin
                                alu_op <= data[0]? alu_op_dcr : alu_op_inr;
                                alu_a <= regs[data[5:3]];
                                dst_reg <= data[5:3];
                                state <= st_alures2reg;
                            end
                    end
                8'b00xxx011:  // DCX / INX
                    begin
                        $display("      %s %s", data[3]? "DCX" : "INX", pairname(data[5:4]));
                        case( data[5:4] )
                            2'b00: {regs[reg_b], regs[reg_c]} <=
                                   {regs[reg_b], regs[reg_c]} + (data[3]? 16'hffff : 16'h1);
                            2'b01: {regs[reg_d], regs[reg_e]} <=
                                   {regs[reg_d], regs[reg_e]} + (data[3]? 16'hffff : 16'h1);
                            2'b10: {regs[reg_h], regs[reg_l]} <=
                                   {regs[reg_h], regs[reg_l]} + (data[3]? 16'hffff : 16'h1);
                            2'b11: sp <= sp + (data[3]? 16'hffff : 16'h1);
                        endcase
                        state <= st_start;
                    end
                8'b01xxxxxx: // MOV reg, reg
                    begin
                        $display("      MOV %s, %s", regname(data[5:3]), regname(data[2:0]));
                        if( data[5:3] == reg_m )
                            begin  // mov m, reg
                                w_data <= regs[data[2:0]];
                                mem_addr <= regs_hl;
                                mem_op <= mem_write;
                                state <= st_start;
                            end
                        else if( data[2:0] == reg_m )
                            begin  // mov reg, m
                                dst_reg <= data[5:3];
                                mem_addr <= regs_hl;
                                mem_op <= mem_read;
                                state <= st_mov_mem2reg;
                            end
                        else
                            begin
                                regs[data[5:3]] <= regs[data[2:0]];
                                state <= st_start;
                            end
                    end
                8'b10xxxxxx: // ADD reg / CMP reg ...
                    begin
                        $display("      %s %s", opname(data[5:3]), regname(data[2:0]));
                        if( data[2:0] == reg_m )
                            begin  // memory alu operation
                                mem_addr <= regs_hl;
                                mem_op <= mem_read;
                                state <= st_alu_mem_op;
                            end
                        else
                            begin
                                alu_op <= `get_alu_op(data);
                                alu_a <= regs[reg_a];
                                alu_b <= regs[data[2:0]];
                                dst_reg <= reg_a;
                                state <= st_alures2reg;
                            end
                    end
                8'b11xxx110: // ADI/CPI/ORI ...
                    begin
                        $display("      %sI nn", opname(data[5:3])); 
                        state <= st_arg2alu;
                    end

                8'b00000111:
                    begin
                        $display("      RLC");
                        { flag_c, regs[reg_a] } <= (regs[reg_a] << 1) + regs[reg_a][7];
                        state <= st_start;
                    end
                8'b00010111:
                    begin
                        $display("      RAL");
                        { flag_c, regs[reg_a] } <= (regs[reg_a] << 1) + flag_c;
                        state <= st_start;
                    end
                8'b00100111: // не тестировал
                    begin
                        $display("      DAA");
                        if (regs[reg_a][3:0] > 9 || flag_ac )
                            { flag_ac, regs[reg_a] } <= regs[reg_a] + 8'h06;
                        state <= st_daa;
                    end
                8'b00110111:
                    begin
                        $display("      STC");
                        flag_c <= 1;
                        state <= st_start;
                    end

                8'b00001111:
                    begin
                        $display("      RRC");
                        regs[reg_a] <= (regs[reg_a] >> 1) + (regs[reg_a][0] << 7);
                        flag_c <= regs[reg_a][0];
                        state <= st_start;
                    end
                8'b00011111:
                    begin
                        $display("      RAR");
                        regs[reg_a] <= (regs[reg_a] >> 1) + (flag_c << 7);
                        flag_c <= regs[reg_a][0];
                        state <= st_start;
                    end
                8'b00101111:
                    begin
                        $display("      CMA");
                        regs[reg_a] = ~regs[reg_a];
                        state <= st_start;
                    end
                8'b00111111:
                    begin
                        $display("      CMC");
                        flag_c <= ~flag_c;
                        state <= st_start;
                    end

                8'b00xx1001:
                    begin
                        $display("      DAD %s", pairname(data[5:4]));
                        case( data[5:4] )
                            2'b00: {flag_c, regs[reg_h], regs[reg_l]} <=
                                           {regs[reg_h], regs[reg_l]} + {regs[reg_b], regs[reg_c]};
                            2'b01: {flag_c, regs[reg_h], regs[reg_l]} <=
                                           {regs[reg_h], regs[reg_l]} + {regs[reg_d], regs[reg_e]};
                            2'b10: {flag_c, regs[reg_h], regs[reg_l]} <=
                                           {regs[reg_h], regs[reg_l]} + {regs[reg_h], regs[reg_l]};
                            2'b11: {flag_c, regs[reg_h], regs[reg_l]} <=
                                           {regs[reg_h], regs[reg_l]} + sp;
                        endcase
                        state <= st_start;
                    end

                8'b11xx0101:
                    begin
                        $display("      PUSH %s", pairname_psw(data[5:4]));
                        mem_addr <= sp - 16'h1;
                        case( data[5:4] )
                            2'b00:  begin
                                        w_data <= regs[reg_b];
                                        w_data2 <= regs[reg_c];
                                    end
                            2'b01:  begin
                                        w_data <= regs[reg_d];
                                        w_data2 <= regs[reg_e];
                                    end
                            2'b10:  begin
                                        w_data <= regs[reg_h];
                                        w_data2 <= regs[reg_l];
                                    end
                            2'b11:  begin
                                        w_data <= regs[reg_a];
                                        w_data2 <= {
                                            flag_s,
                                            flag_z,
                                            1'b0,
                                            flag_ac,
                                            1'b0,
                                            flag_p,
                                            1'b1,
                                            flag_c
                                        };
                                    end
                        endcase
                        mem_op <= mem_write;
                        state <= st_push;
                    end
                8'b11xx0001:
                    begin
                        $display("      POP %s", pairname_psw(data[5:4]));
                        mem_addr <= sp;
                        mem_op <= mem_read;
                        dst_reg <= {1'b0, data[5:4]};
                        state <= st_pop;
                    end

                8'b11000011:
                    begin
                        $display("      JMP");
                        mem_op <= mem_pc1;
                        state <= st_jmp;
                    end
                8'b11xxx010:
                    begin
                        $display("      J%s", cond_str(data[5:3]));
                        if( cond_ok )
                            begin
                                mem_op <= mem_pc1;
                                state <= st_jmp;
                            end
                        else
                            begin
                                $display("      no jump");
                                pc <= pc + 16'h2;
                                state <= st_start;
                            end
                    end
                8'b11001101:
                    begin
                        $display("      CALL");
                        state <= st_call;
                    end
                8'b11xxx100:
                    begin
                        $display("      C%s", cond_str(data[5:3]));
                        if( cond_ok )
                            state <= st_call;
                        else
                            begin
                                $display("      no call");
                                pc <= pc + 16'h2;
                                state <= st_start;
                            end
                    end
                8'b11001001:
                    begin
                        $display("      RET");
                        mem_addr <= sp;
                        mem_op <= mem_read;
                        state <= st_ret;
                    end
                8'b11xxx000:
                    begin
                        $display("      R%s", cond_str(data[5:3]));
                        if( cond_ok )
                            begin
                                mem_addr <= sp;
                                mem_op <= mem_read;
                                state <= st_ret;
                            end
                        else
                            state <= st_start;
                    end
                8'b11xxx111:
                    begin
                        $display("      RST %h (pc = %h)", data[5:3], pc);
                        { w_data2, w_data } <= pc;
                        mem_addr <= sp - 16'h2;
                        mem_op <= mem_write;
                        dst_reg <= data[5:3];
                        state <= st_rst;
                    end
                8'b11100011:
                    begin
                        $display("      XTHL");
                        mem_addr <= sp;
                        mem_op <= mem_read;
                        state <= st_xthl;
                    end
                8'b11101011:
                    begin
                        $display("      XCHG");
                        regs[reg_l] <= regs[reg_e];
                        regs[reg_h] <= regs[reg_d];
                        regs[reg_e] <= regs[reg_l];
                        regs[reg_d] <= regs[reg_h];
                        state <= st_start;
                    end
                8'b11110011:
                    begin
                        $display("      DI");
                        ie <= 0;
                        state <= st_start;
                    end
                8'b11111011:
                    begin
                        $display("      EI");
                        ie <= 1;
                        state <= st_start;
                    end
                8'b11111001:
                    begin
                        $display("      SPHL");
                        sp <= { regs[reg_h], regs[reg_l] };
                        state <= st_start;
                    end
                8'b11101001:
                    begin
                        $display("      PCHL");
                        pc <= { regs[reg_h], regs[reg_l] };
                        state <= st_start;
                    end
                8'b11010011:
                    begin
                        $display("      OUT nn");
                        state <= st_out;
                    end
                8'b11011011:
                    begin
                        $display("      IN nn");
                        state <= st_in;
                    end
                    
                8'b00000000:
                    begin
                        $display("      NOP");
                        state <= st_start;
                    end
                default:
                    begin
                        $display("     ??? (code: %h)", data);
                        state <= st_start;
                    end
            endcase
            end
        
        //  --- 3 tick ---

        st_mov_arg2reg:
            begin
                $display("      mem[%h] %h -> reg %s", addr, data, regname(dst_reg));
                pc <= pc + 16'h1;
                if( dst_reg == reg_m )
                    begin
                        w_data <= data;
                        mem_addr <= regs_hl;
                        mem_op <= mem_write;
                    end
                else
                    begin
                        regs[dst_reg] <= data;
                    end
                state <= st_start;
            end
        st_mov_mem2reg:
            begin
                $display("      %h -> reg %s", data, regname(dst_reg));
                regs[dst_reg] <= data;
                state <= st_start;
            end
        st_mov_arg2reg_pair:
            begin
                if( dst_reg[1:0] != 3'b11 )
                    $display("      %h -> reg %s", data, regname({dst_reg[1:0], ~dst_reg[2]}));
                else
                    $display("      %h -> SP (%s byte)", data, dst_reg[2]? "high" : "low ");
                case( dst_reg )
                    3'b000: regs[reg_c] <= data;
                    3'b001: regs[reg_e] <= data;
                    3'b010: regs[reg_l] <= data;
                    3'b011:     sp[7:0] <= data;
                    3'b100: regs[reg_b] <= data;
                    3'b101: regs[reg_d] <= data;
                    3'b110: regs[reg_h] <= data;
                    3'b111:    sp[15:8] <= data;
                endcase
                dst_reg[2] <= 1;
                pc <= pc + 16'h1;
                state <= dst_reg[2]? st_start : st_mov_arg2reg_pair;
            end
        st_lhld:
            begin
                $display("      ldld %h - low byte", data);
                jmp_addr <= data;
                pc <= pc + 16'h1;
                state <= st_lhld_2;
            end
        st_lhld_2:
            begin
                $display("      ldld %h - high byte", data);
                mem_addr <= { data, jmp_addr };
                mem_op <= mem_read;
                pc <= pc + 16'h1;
                state <= st_lhld_3;
            end
        st_lhld_3:
            begin
                $display("      ldld  %h -> l", data);
                regs[reg_l] <= data;
                mem_addr <= mem_addr + 16'h1;
                mem_op <= mem_read;
                state <= st_lhld_4;
            end
        st_lhld_4:
            begin
                $display("      ldld  %h -> h", data);
                regs[reg_h] <= data;
                state <= st_start;
            end
        st_lda1:
            begin
                $display("      lda %h - low byte", data);
                mem_addr[7:0] <= data;
                pc <= pc + 16'h1;
                state <= st_lda2;
            end
        st_lda2:
            begin
                $display("      lda %h - high byte", data);
                mem_addr[15:8] <= data;
                mem_op <= mem_read;
                dst_reg <= reg_a;
                pc <= pc + 16'h1;
                state <= st_mov_mem2reg;
            end
        st_sta1:
            begin
                $display("      sda %h - low byte", data);
                mem_addr[7:0] <= data;
                pc <= pc + 16'h1;
                state <= st_sta2;
            end
        st_sta2:
            begin
                $display("      sda %h - high byte", data);
                mem_addr[15:8] <= data;
                mem_op <= mem_write;
                w_data <= regs[reg_a];
                pc <= pc + 16'h1;
                state <= st_start;
            end
        st_shld:
            begin
                $display("      shld %h - low byte", data);
                mem_addr[7:0] <= data;
                pc <= pc + 16'h1;
                state <= st_shld_1;
            end
        st_shld_1:
            begin
                $display("      shld %h - high byte", data);
                mem_addr[15:8] <= data;
                mem_op <= mem_write;
                w_data <= regs[reg_l];
                pc <= pc + 16'h1;
                state <= st_shld_2;
            end
        st_shld_2:
            begin
                $display("      shld save h");
                mem_addr <= mem_addr + 16'h1;
                mem_op <= mem_write;
                w_data <= regs[reg_h];
                state <= st_start;
            end
        st_arg2alu:
            begin
                $display("      mem[%h] %h -> alu op2 ", addr, data);
                alu_op <= `get_alu_op(cmd);
                alu_b <= data;
                alu_a <= regs[reg_a];
                dst_reg <= reg_a;
                pc <= pc + 16'h1;
                state <= st_alures2reg;
            end
        st_alures2reg:
            begin
                $display("      alu %h -> reg ", alu_res, regname(dst_reg));
                flag_z  = alu_flag_z;
                flag_ac = alu_flag_ac;
                flag_s  = alu_flag_s;
                flag_c  = alu_flag_c;
                flag_p  = alu_flag_p;
                if( dst_reg == reg_m )
                    begin
                        w_data <= alu_res;
                        mem_addr <= regs_hl;
                        mem_op <= mem_write;
                    end
                else
                    begin
                        regs[dst_reg] <= alu_res;
                    end
                state <= st_start;
            end
        st_alures2mem:
            begin
                $display("      alu op1 <- %h", data);
                alu_a <= data;
                alu_op <= cmd[0]? alu_op_dcr : alu_op_inr;
                dst_reg <= reg_m;
                state <= st_alures2reg;
            end
        st_alu_mem_op:
            begin
                $display("      %s with %h (from mem)", opname(cmd[5:3]), data);
                alu_op <= `get_alu_op(cmd);
                alu_a <= regs[reg_a];
                alu_b <= data;
                dst_reg <= reg_a;
                state <= st_alures2reg;
            end
        st_daa: // не тестировал
            begin
                $display("      DAA step2");
                if(regs[reg_a][7:4] > 9 || flag_c )
                    { flag_c, regs[reg_a] } <= regs[reg_a] + 8'h60;
                state <= st_start;
            end
        st_push:
            begin
                $display("      PUSH high byte");
                mem_addr <= sp - 16'h2;
                mem_op <= mem_write;
                w_data <= w_data2;
                sp <= sp - 16'h2;
                state <= st_start;
            end
        st_pop:
            begin
                sp <= sp + 16'h1;
                $display("      %h -> reg pair ", data, pairname_psw(dst_reg[1:0]));
                case( dst_reg )
                    3'b000: regs[reg_c] <= data;
                    3'b001: regs[reg_e] <= data;
                    3'b010: regs[reg_l] <= data;
                    3'b011: begin
                                flag_s  <= data[7];
                                flag_z  <= data[6];
                                flag_ac <= data[4];
                                flag_p  <= data[2];
                                flag_c  <= data[0];
                            end
                    3'b100: regs[reg_b] <= data;
                    3'b101: regs[reg_d] <= data;
                    3'b110: regs[reg_h] <= data;
                    3'b111: regs[reg_a] <= data;
                endcase
                if( dst_reg[2] )
                    state <= st_start;
                else
                    begin
                        dst_reg[2] <= 1;
                        mem_addr <= sp + 16'h1;
                        mem_op <= mem_read;
                        state <= st_pop;
                    end
            end
        st_jmp:
            begin
                $display("      do jump. low byte %h", data);
                pc <= pc + 16'h1;
                jmp_addr <= data;
                state <= st_jmp_now;
            end
        st_jmp_now:
            begin
                $display("      do jump to %h", { data, jmp_addr });
                pc <= { data, jmp_addr };
                state <= st_start;
            end
        st_call:
            begin
                $display("      do call. push pc (low byte)");
                { w_data2, w_data } <= pc + 16'h2;
                mem_addr <= sp - 16'h2;
                mem_op <= mem_write;
                state <= st_call_push_pc_l;
            end
        st_call_push_pc_l:
            begin
                $display("      do call. push pc (high byte)");
                w_data <= w_data2;
                mem_addr <= sp - 16'h1;
                mem_op <= mem_write;
                state <= st_call_push_pc_h;
            end
        st_call_push_pc_h:
            begin
                $display("      do call. sp = sp - 2");
                sp <= sp - 16'h2;
                state <= st_call_jmp;
            end
        st_call_jmp:
            begin
                $display("      prepare jump. %h -> pc low", data);
                jmp_addr <= data;
                mem_op <= mem_read;
                mem_addr <= pc + 16'h1;
                state <= st_jmp_now;
            end

        st_rst:
            begin
                $display("      do rst call. push pc high byte and jmp %h", (dst_reg << 3));
                w_data <= w_data2;
                mem_addr <= sp - 16'h1;
                mem_op <= mem_write;
                sp <= sp - 16'h2;
                pc <= dst_reg << 3;
                state <= st_start;
            end

        st_ret:
            begin
                $display("      sp[%h] %h -> pc (low byte)", addr, data);
                jmp_addr <= data;
                mem_addr <= sp + 16'h1;
                mem_op <= mem_read;
                state <= st_ret_now;
            end
        st_ret_now:
            begin
                $display("      sp[%h] %h -> pc (high byte)", addr, data);
                sp <= sp + 16'h2;
                pc <= { data, jmp_addr };
                state <= st_start;
            end
        st_xthl:
            begin
                $display("      [sp] <-> l. %h -> l, %h -> [%h]", data, regs[reg_l], sp);
                w_data <= regs[reg_l];
                regs[reg_l] <= data;
                mem_addr <= sp;
                mem_op <= mem_write;
                state <= st_xthl_2;
            end
        st_xthl_2:
            begin
                $display("      xthl. read from sp + 1");
                mem_addr <= sp + 16'h1;
                mem_op <= mem_read;
                state <= st_xthl_3;
            end
        st_xthl_3:
            begin
                $display("      [sp+1] <-> h");
                w_data <= regs[reg_h];
                regs[reg_h] <= data;
                mem_addr <= sp + 16'h1;
                mem_op <= mem_write;
                state <= st_idle_clock;
            end
        st_out:
            begin
                $display("      out to port %h", data);
                pc <= pc + 16'h1;
                w_data <= regs[reg_a];
                mem_addr <= { 8'h0, data };
                mem_op <= mem_io_out;
                state <= st_start;
            end
        st_in:
            begin
                $display("      read from port %h", data);
                pc <= pc + 16'h1;
                mem_addr <= { 8'h0, data };
                mem_op <= mem_io_in;
                state <= st_in_wait;
            end
        st_in_wait:
            begin
                $display("      wating read from port %h", mem_addr);
                mem_op <= mem_io_in;
                state <= st_in_now;
            end
        st_in_now:
            begin
                $display("      read %h from port %h now", data, mem_addr);
                regs[reg_a] <= data;
                mem_op <= mem_pc;
                state <= st_start;
            end
        default:
            begin
                $display("unknown state!");
                state <= st_start;
            end
      endcase
      end
end

wire [8:0] alu_tmp_res;
assign alu_tmp_res =
    (alu_op == alu_op_add) ? alu_a + alu_b :
    (alu_op == alu_op_adc) ? alu_a + alu_b + flag_c :
    (alu_op == alu_op_sub) ? alu_a - alu_b :
    (alu_op == alu_op_sbb) ? alu_a - alu_b - flag_c :
    (alu_op == alu_op_inr) ? alu_a + 1 :
    (alu_op == alu_op_dcr) ? alu_a - 1 :
    (alu_op == alu_op_xor) ? { 1'b0, alu_a ^ alu_b } :
    (alu_op == alu_op_or)  ? { 1'b0, alu_a | alu_b } :
    (alu_op == alu_op_and) ? { 1'b0, alu_a & alu_b } :
    (alu_op == alu_op_cmp) ? alu_a - alu_b : 0;

reg alu_flag_z;
reg alu_flag_ac;
reg alu_flag_s;
reg alu_flag_c;
reg alu_flag_p;

always @(negedge clk)
begin
    if( alu_op != alu_op_none )
        begin
            if( (alu_op != alu_op_inr) && (alu_op != alu_op_dcr) )
                begin
                    $display("[ALU] %s(%h, %h)", opname(alu_op), alu_a, alu_b);
                    alu_flag_c <= alu_tmp_res[8];
                end
            else
                $display("[ALU] %s(%h)", opname(alu_op), alu_a);
            alu_res <= (alu_op != alu_op_cmp) ? alu_tmp_res[7:0] : alu_a;
            alu_flag_z <= ~|alu_tmp_res[7:0];
            alu_flag_s <= alu_tmp_res[7];
            alu_flag_p <= ~^alu_tmp_res[7:0];
        end
    case( alu_op )
        alu_op_add:
            alu_flag_ac <= (((alu_a[3:0] + alu_b[3:0]) >> 4) & 8'b1) ? 1'b1 : 1'b0;
        alu_op_adc:
            alu_flag_ac <= (((alu_a[3:0] + alu_b[3:0] + flag_c) >> 4) & 8'b1) ? 1'b1 : 1'b0;
        alu_op_inr:
            alu_flag_ac <= (alu_a[3:0] == 4'b1111) ? 1'b1 : 1'b0;
        alu_op_sub, alu_op_cmp:
            alu_flag_ac <= (((alu_a[3:0] - alu_b[3:0]) >> 4) & 8'b1) ? 1'b1 : 1'b0;
        alu_op_sbb:
            alu_flag_ac <= (((alu_a[3:0] - alu_b[3:0] - flag_c) >> 4) & 8'b1) ? 1'b1 : 1'b0;
        alu_op_dcr:
            alu_flag_ac <= (alu_a[3:0] == 4'b0000) ? 1'b1 : 1'b0;
        alu_op_none:;
        default:
            alu_flag_ac <= 0;
    endcase
end
endmodule
