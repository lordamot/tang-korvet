`timescale 1ns / 1ps
//========================================================================
// pit8253.v - the КР580ВИ53 programmable timer, three counters.
//
// On the Корвет: counter 0 is the sound (2 MHz in, its output gated by
// the ВВ55 #2's port C bit 3 onto the piezo), counter 1 the serial
// port's baud clock (2 MHz in, x16 or x64 in the ВВ51), counter 2 the
// interrupt timer (HBL in, 15.2 kHz, out to IRQ5).  Each counter has a
// clock enable, a gate and an output; the CPU sees four registers.
//
// Modes 0-5 as the datasheet has them, binary; BCD is decoded and
// ignored.  A new count takes effect on the next clock for the modes
// that allow it and on the gate for mode 1 and 5.  Read-back: the
// latch command freezes the count for the next read pair.  Not
// cycle-exact at the edges - the chip counts on its clock's falling
// edge and reloads a clock later - but the periods and the shapes are
// right, which is what the software listens to.
//========================================================================
module pit8253 (
    input             clk,
    input             reset,

    input             wr,
    input             rd,
    input      [1:0]  a,
    input      [7:0]  wdata,
    output reg [7:0]  rdata,

    input      [2:0]  ce,           // one-clock enables: the counters' clocks
    input      [2:0]  gate,
    output     [2:0]  out
);

genvar n;
generate for (n = 0; n < 3; n = n + 1) begin : c
    reg [15:0] count  = 16'd0;
    reg [15:0] reload = 16'd0;
    reg [15:0] latch  = 16'd0;
    reg        latched = 1'b0;
    reg [2:0]  mode   = 3'd0;
    reg [1:0]  rw     = 2'd3;      // 01 low, 10 high, 11 low then high
    reg        wr_hi  = 1'b0;      // the next write is the high byte
    reg        rd_hi  = 1'b0;
    reg        loaded = 1'b0;      // a count has been written since the mode
    reg        armed  = 1'b0;      // waiting for the gate (modes 1, 5) or the first clock
    reg        o      = 1'b1;
    reg        gate_d = 1'b0;
    reg        half   = 1'b0;      // mode 3: the second half
    wire [7:0] rd_byte;            // what a read of this counter gives

    wire sel = (a == n[1:0]);
    wire ctl = wr && (a == 2'd3) && (wdata[7:6] == n[1:0]);
    wire g_rise = gate[n] && !gate_d;
    wire [15:0] next = count - 16'd1;

    assign out[n] = o;
    assign rd_byte = (rw == 2'd1) ? (latched ? latch[7:0]  : count[7:0]) :
                     (rw == 2'd2) ? (latched ? latch[15:8] : count[15:8]) :
                     !rd_hi       ? (latched ? latch[7:0]  : count[7:0]) :
                                    (latched ? latch[15:8] : count[15:8]);

    always @(posedge clk) begin
        gate_d <= gate[n];
        if (reset) begin
            mode <= 3'd0; rw <= 2'd3; o <= 1'b1; loaded <= 1'b0; armed <= 1'b0;
            wr_hi <= 1'b0; rd_hi <= 1'b0; latched <= 1'b0; count <= 16'd0; reload <= 16'd0;
        end else begin
            // the control word
            if (ctl) begin
                if (wdata[5:4] == 2'd0) begin
                    latch <= count; latched <= 1'b1;          // counter latch
                end else begin
                    mode  <= wdata[3:1];
                    rw    <= wdata[5:4];
                    wr_hi <= (wdata[5:4] == 2'd2);
                    rd_hi <= (wdata[5:4] == 2'd2);
                    loaded <= 1'b0; armed <= 1'b0;
                    o <= (wdata[3:1] == 3'd0) ? 1'b0 : 1'b1;   // mode 0 starts low
                end
            end
            // the count
            if (wr && sel) begin
                if (rw == 2'd1)           reload[7:0]  <= wdata;
                else if (rw == 2'd2)      reload[15:8] <= wdata;
                else if (!wr_hi)          reload[7:0]  <= wdata;
                else                      reload[15:8] <= wdata;
                if (rw == 2'd3) wr_hi <= ~wr_hi;
                if (rw != 2'd3 || wr_hi) begin
                    loaded <= 1'b1;
                    armed  <= 1'b1;                            // (re)start on the next clock / gate
                    if (mode == 3'd0) o <= 1'b0;
                end
            end
            // reading: the byte is rd_byte, taken by the module's one rdata
            // register below (Gowin wants one driver); the bookkeeping is here
            if (rd && sel) begin
                if (rw == 2'd1)       latched <= 1'b0;
                else if (rw == 2'd2)  latched <= 1'b0;
                else if (!rd_hi)      rd_hi <= 1'b1;
                else                  begin rd_hi <= 1'b0; latched <= 1'b0; end
            end
            // counting
            if (ce[n] && loaded) begin
                case (mode)
                3'd0: if (armed) begin count <= reload; armed <= 1'b0; end
                      else if (gate[n]) begin
                          count <= next;
                          if (next == 16'd0) o <= 1'b1;
                      end
                3'd1: if (g_rise || (armed && gate[n])) begin count <= reload; armed <= 1'b0; o <= 1'b0; end
                      else begin
                          count <= next;
                          if (next == 16'd0) o <= 1'b1;
                      end
                3'd2: if (armed || !gate[n]) begin count <= reload; o <= 1'b1; if (gate[n]) armed <= 1'b0; end
                      else begin
                          if (count == 16'd2) o <= 1'b0;
                          if (count == 16'd1) begin o <= 1'b1; count <= reload; end
                          else count <= next;
                      end
                3'd3: if (armed || !gate[n]) begin count <= reload; o <= 1'b1; half <= 1'b0; if (gate[n]) armed <= 1'b0; end
                      else begin
                          // by two; an odd count gives the high half one clock more
                          if (count <= 16'd2) begin
                              o     <= ~o;
                              count <= reload - ((reload[0] && o) ? 16'd1 : 16'd0);
                          end else
                              count <= count - 16'd2;
                      end
                3'd4: if (armed) begin count <= reload; armed <= 1'b0; o <= 1'b1; end
                      else if (gate[n]) begin
                          count <= next;
                          o <= (next != 16'd0);
                      end
                default: if (g_rise || (armed && gate[n])) begin count <= reload; armed <= 1'b0; o <= 1'b1; end
                      else begin
                          count <= next;
                          o <= (next != 16'd0);
                      end
                endcase
            end
        end
    end
end endgenerate

always @(posedge clk)
    if (rd) case (a)
        2'd0: rdata <= c[0].rd_byte;
        2'd1: rdata <= c[1].rd_byte;
        2'd2: rdata <= c[2].rd_byte;
        default: rdata <= 8'hFF;
    endcase

endmodule
