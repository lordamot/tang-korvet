`timescale 1ns / 1ps
//========================================================================
// poke.v - the MCU's way into the machine's RAM while it runs.
//
// sysctrl.v's CMD 6 carries an address and then any number of bytes;
// each arrives here as a one-clock strobe.  They are queued sixteen deep
// and handed to membus.v's write queue as it has room, so the SPI link's
// pace and the CPU's own traffic never meet.  Nothing here knows what
// the bytes are: a byte to an address.  The testbench's +POKE= uses it;
// the firmware has no use for it yet on this machine.
//========================================================================
module poke (
    input             clk,
    input             reset,

    input             stb,          // a byte from sysctrl.v
    input      [15:0] adr,
    input      [7:0]  data,

    input             room,         // membus.v can take one
    output            req,          // one clock: write req_data to req_adr
    output     [15:0] req_adr,
    output     [7:0]  req_data,
    output            pending
);

reg [23:0] fifo [0:15];
reg [4:0]  wp = 5'd0, rp = 5'd0;

wire empty = (wp == rp);
wire full  = (wp[3:0] == rp[3:0]) && (wp[4] != rp[4]);

assign pending  = !empty;
assign req      = !empty && room;
assign req_adr  = fifo[rp[3:0]][23:8];
assign req_data = fifo[rp[3:0]][7:0];

always @(posedge clk) begin
    if (reset) begin
        wp <= 5'd0; rp <= 5'd0;
    end else begin
        if (stb && !full) begin
            fifo[wp[3:0]] <= {adr, data};
            wp <= wp + 5'd1;
        end
        if (req) rp <= rp + 5'd1;
    end
end

endmodule
