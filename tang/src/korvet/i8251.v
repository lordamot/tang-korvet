`timescale 1ns / 1ps
//========================================================================
// i8251.v - the КР580ВВ51А serial adapter, asynchronous mode.
//
// Two on the Корвет: #1 (D10) is the RS-232 / current-loop port, clocked
// by the timer's counter 1, with its receiver on IRQ1 and transmitter on
// IRQ2 - and the port a serial mouse plugs into (mouse.v); #2 (D11) is
// the classroom network at a fixed 19.2 kbit/s, receiver on IRQ3, with
// nothing on the line here.
//
// The programming model as the datasheet gives it: after reset the
// first control write is the mode (baud factor bits 1:0 - 01 x1, 10
// x16, 11 x64; character length bits 3:2, 5..8 bits; parity enable bit
// 4, even bit 5; stop bits 7:6), then command words (TxEN bit 0, DTR
// bit 1, RxE bit 2, break bit 3, error reset bit 4, RTS bit 5, internal
// reset bit 6 - back to wanting a mode - hunt bit 7).  Status: TxRDY,
// RxRDY, TxEMPTY, PE, OE, FE, SYNDET, DSR (bit 7: the pin, active low,
// reads 1 when asserted).  Synchronous mode is not implemented.
//
// The receiver samples RxD on the rising edges of RxC - a level from the
// timer, edge-detected here - counting the factor's samples a bit, and
// starts on a low seen at mid-start-bit.  The transmitter shifts on TxC
// the same way.  Everything is on `clk`.
//========================================================================
module i8251 (
    input             clk,
    input             reset,

    input             wr,
    input             rd,
    input             a0,           // 0 data, 1 control/status
    input      [7:0]  wdata,
    output reg [7:0]  rdata,

    input             rxc,          // the baud clock, a level
    input             txc,
    input             rxd,
    output reg        txd,
    input             dsr_n,        // 0 = asserted
    output            dtr_n,
    output            rts_n,

    output            rxrdy,
    output            txrdy
);

reg        want_mode = 1'b1;
reg  [7:0] mode = 8'd0, cmd = 8'd0;
reg  [7:0] rx_data = 8'd0, tx_data = 8'd0;
reg        rx_full = 1'b0, tx_full = 1'b0, tx_busy = 1'b0;
reg        pe = 1'b0, oe = 1'b0, fe = 1'b0;

wire       txen = cmd[0];
wire       rxen = cmd[2];
assign     dtr_n = ~cmd[1];
assign     rts_n = ~cmd[5];
assign     rxrdy = rx_full && rxen;
assign     txrdy = !tx_full && txen;
wire       txempty = !tx_full && !tx_busy;

wire [2:0] nbits  = 3'd5 + {1'b0, mode[3:2]};         // data bits
wire       par_en = mode[4];
wire       par_ev = mode[5];
wire [6:0] factor = (mode[1:0] == 2'd1) ? 7'd1 : (mode[1:0] == 2'd2) ? 7'd16 : 7'd64;

//------------------------------------------------------------------------
// The CPU
//------------------------------------------------------------------------
always @(posedge clk) begin
    if (reset) begin
        want_mode <= 1'b1; mode <= 8'd0; cmd <= 8'd0; rx_full <= 1'b0; tx_full <= 1'b0;
        pe <= 1'b0; oe <= 1'b0; fe <= 1'b0;
    end else begin
        if (wr) begin
            if (a0) begin
                if (want_mode) begin mode <= wdata; want_mode <= 1'b0; end
                else begin
                    cmd <= wdata;
                    if (wdata[6]) begin want_mode <= 1'b1; cmd <= 8'd0; end
                    if (wdata[4]) begin pe <= 1'b0; oe <= 1'b0; fe <= 1'b0; end
                end
            end else begin
                tx_data <= wdata; tx_full <= 1'b1;
            end
        end
        if (rd) begin
            if (a0) rdata <= {~dsr_n, 1'b0, fe, oe, pe, txempty, rxrdy, txrdy};
            else begin rdata <= rx_data; rx_full <= 1'b0; end
        end
        if (rx_done) begin
            if (rx_full) oe <= 1'b1;
            rx_data <= rx_shift; rx_full <= 1'b1;
            if (rx_pe) pe <= 1'b1;
            if (rx_fe) fe <= 1'b1;
        end
        if (tx_take) tx_full <= 1'b0;
    end
end

//------------------------------------------------------------------------
// The receiver
//------------------------------------------------------------------------
reg        rxc_d = 1'b0, txc_d = 1'b0;
wire       rxc_e = rxc && !rxc_d;
wire       txc_e = txc && !txc_d;
always @(posedge clk) begin rxc_d <= rxc; txc_d <= txc; end

reg  [6:0] rx_cnt = 7'd0;           // samples into the bit
reg  [3:0] rx_bit = 4'd0;           // 0 idle, 1 start, 2.. data, then parity, stop
reg  [7:0] rx_shift = 8'd0;
reg  [7:0] rx_acc = 8'd0;
reg        rx_par = 1'b0;
reg        rx_done = 1'b0, rx_pe = 1'b0, rx_fe = 1'b0;
reg        rxd_s = 1'b1;

wire [6:0] half = {1'b0, factor[6:1]};

always @(posedge clk) begin
    rx_done <= 1'b0;
    rxd_s   <= rxd;
    if (reset || !rxen) begin
        rx_bit <= 4'd0; rx_cnt <= 7'd0;
    end else if (rxc_e) begin
        if (rx_bit == 4'd0) begin
            if (!rxd_s) begin rx_bit <= 4'd1; rx_cnt <= 7'd1; rx_par <= 1'b0; end
        end else if (rx_bit == 4'd1) begin
            // the start bit: confirm it at its middle
            if (rx_cnt == half || factor == 7'd1) begin
                if (rxd_s || factor == 7'd1) begin
                    if (rxd_s) rx_bit <= 4'd0;
                    else begin rx_bit <= 4'd2; rx_cnt <= 7'd0; rx_acc <= 8'd0; end
                end else begin rx_bit <= 4'd2; rx_cnt <= 7'd0; rx_acc <= 8'd0; end
            end else
                rx_cnt <= rx_cnt + 7'd1;
        end else begin
            if (rx_cnt == factor - 7'd1) begin
                rx_cnt <= 7'd0;
                if (rx_bit - 4'd2 < {1'b0, nbits}) begin
                    rx_acc <= {rxd_s, rx_acc[7:1]};
                    rx_par <= rx_par ^ rxd_s;
                    rx_bit <= rx_bit + 4'd1;
                end else if (par_en && (rx_bit - 4'd2 == {1'b0, nbits})) begin
                    rx_par <= rx_par ^ rxd_s;
                    rx_bit <= rx_bit + 4'd1;
                end else begin
                    // the stop bit
                    rx_shift <= rx_acc >> (4'd8 - {1'b0, nbits});
                    rx_fe    <= !rxd_s;
                    rx_pe    <= par_en && (par_ev ? rx_par : ~rx_par);
                    rx_done  <= 1'b1;
                    rx_bit   <= 4'd0;
                end
            end else
                rx_cnt <= rx_cnt + 7'd1;
        end
    end
end

//------------------------------------------------------------------------
// The transmitter
//------------------------------------------------------------------------
reg  [6:0] tx_cnt = 7'd0;
reg  [3:0] tx_bit = 4'd0;
reg  [9:0] tx_shift = 10'h3FF;
reg  [3:0] tx_len = 4'd0;
reg        tx_take = 1'b0;
wire       tx_par = par_en ? (par_ev ? ^tx_data[7:0] : ~^tx_data[7:0]) : 1'b1;

always @(posedge clk) begin
    tx_take <= 1'b0;
    if (reset) begin
        txd <= 1'b1; tx_busy <= 1'b0; tx_bit <= 4'd0;
    end else if (cmd[3]) begin
        txd <= 1'b0;                                   // break
    end else if (txc_e) begin
        if (!tx_busy) begin
            txd <= 1'b1;
            if (tx_full && txen) begin
                // start, data (LSB first), parity, stop
                tx_shift <= {tx_par, tx_data, 1'b0};
                tx_len   <= 4'd1 + {1'b0, nbits} + {3'd0, par_en} + 4'd1;
                tx_bit   <= 4'd0; tx_cnt <= 7'd0;
                tx_busy  <= 1'b1;
                tx_take  <= 1'b1;
            end
        end else begin
            if (tx_cnt == 7'd0) begin
                txd      <= (tx_bit == tx_len - 4'd1) ? 1'b1 : tx_shift[0];
                tx_shift <= {1'b1, tx_shift[9:1]};
            end
            if (tx_cnt == factor - 7'd1) begin
                tx_cnt <= 7'd0;
                tx_bit <= tx_bit + 4'd1;
                if (tx_bit == tx_len - 4'd1) tx_busy <= 1'b0;
            end else
                tx_cnt <= tx_cnt + 7'd1;
        end
    end
end

endmodule
