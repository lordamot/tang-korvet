`timescale 1ns / 1ps
//========================================================================
// romload.v - a ROM image from the SD card into the SDRAM.
//
// The OSD's "OPTS ROM" slot (sd_card.v's slot 4) takes a file of up to
// 32 KB - a ОПТС of 24 KB, or 8 or 16 KB for the first one or two
// eights.  When the firmware mounts it this copies it, a sector at a
// time through the arbiter into a 512-byte buffer and from there a byte
// a T-state through membus.v's loader port into the ROM region, holding
// the CPU in reset meanwhile (top.v: `loading` is a reset).  `loaded`
// then says the machine's ROM reads come from the SDRAM instead of the
// built-in ОПТС 2.0 (opts_rom.v); ejecting the file clears it and the
// built-in ROM is back.  The image's size is rounded up to a sector;
// the bytes past its end are whatever was there.
//
// `mounted`/`image_size` are never under the CPU reset: the firmware
// mounts while it holds the machine in reset (PK8000 Nano's lesson).
//========================================================================
module romload (
    input             clk,
    input             reset,        // mist_rst

    input             mounted,      // one clock: the slot's image changed
    input      [31:0] image_size,   // 0 = ejected

    // the SD path (sd_arbiter.v client)
    output reg        sd_rd,
    output reg [31:0] sd_sector,
    input             sd_ack,
    input             sd_done,
    input             outen,
    input      [8:0]  outaddr,
    input      [7:0]  outbyte,

    // membus.v's loader port
    output            loading,      // hold the CPU
    output reg        ld_req,
    output reg [14:0] ld_adr,
    output     [7:0]  ld_data,
    input             ld_ack,

    output reg        loaded,       // the SDRAM copy is valid
    output reg [15:0] size          // bytes copied (for the testbench)
);

reg [7:0] buf_ [0:511];
reg [8:0] rd_i = 9'd0;
reg [8:0] wr_i = 9'd0;
reg [6:0] sectors = 7'd0;   // to copy, 1..64
reg [6:0] sec_n   = 7'd0;   // done

localparam [1:0] S_IDLE = 2'd0, S_READ = 2'd1, S_COPY = 2'd2;
reg [1:0] state = S_IDLE;
assign loading = (state != S_IDLE);
assign ld_data = buf_[wr_i];

always @(posedge clk) if (outen && sd_ack) buf_[outaddr] <= outbyte;

always @(posedge clk) begin
    if (reset) begin
        state <= S_IDLE; sd_rd <= 1'b0; loaded <= 1'b0; ld_req <= 1'b0; size <= 16'd0;
    end else begin
        if (mounted) begin
            if (image_size == 32'd0 || image_size > 32'd32768) begin
                loaded <= 1'b0; state <= S_IDLE; sd_rd <= 1'b0; ld_req <= 1'b0;
            end else begin
                sectors <= image_size[15:9] + {6'd0, |image_size[8:0]};
                sec_n   <= 7'd0;
                size    <= image_size[15:0];
                loaded  <= 1'b0;
                state   <= S_READ;
                sd_sector <= 32'd0;
                sd_rd   <= 1'b1;
            end
        end else case (state)
            S_READ: begin
                if (sd_ack) sd_rd <= 1'b0;
                if (sd_done) begin
                    state <= S_COPY;
                    wr_i  <= 9'd0;
                    ld_adr <= {sec_n[5:0], 9'd0};
                    ld_req <= 1'b1;
                end
            end
            S_COPY: begin
                if (ld_ack) begin
                    if (wr_i == 9'd511) begin
                        ld_req <= 1'b0;
                        sec_n  <= sec_n + 7'd1;
                        if (sec_n + 7'd1 == sectors) begin
                            state  <= S_IDLE;
                            loaded <= 1'b1;
                        end else begin
                            state     <= S_READ;
                            sd_sector <= {25'd0, sec_n + 7'd1};
                            sd_rd     <= 1'b1;
                        end
                    end else begin
                        wr_i   <= wr_i + 9'd1;
                        ld_adr <= ld_adr + 15'd1;
                    end
                end
            end
            default: ;
        endcase
    end
end

endmodule
