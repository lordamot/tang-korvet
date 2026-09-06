`timescale 1ns / 1ps
//========================================================================
// mouse.v - a Microsoft serial mouse on the RS-232 port, from USB.
//
// What the Корвет's mouse software (Abris, Spred; MAME wires the same)
// listens for on the ВВ51 #1: 1200 baud, seven data bits, one stop, no
// parity, three bytes a report -
//   1 L R Y7 Y6 X7 X6    the sync byte: bit 6 set, buttons, the top two
//   0 X5 X4 X3 X2 X1 X0    bits of each signed displacement
//   0 Y5 Y4 Y3 Y2 Y1 Y0
// right and DOWN positive, which is what USB reports too - and the
// letter M about 14 ms after the port raises RTS, the sign of life a
// driver waits for.  The USB reports come from hid.v as they arrive
// (a toggle with the signed dx, dy and the two buttons); this sums them
// and sends a report whenever there is something to say and the line
// is free, 40 a second at most.  The bit clock is the system clock
// divided; the ВВ51 samples it with its own x16 clock from the timer,
// which is the machine's business and how a real mouse meets it.
//========================================================================
module mouse (
    input             clk,
    input             reset,
    input             en,

    // hid.v's report
    input             rep_tgl,
    input      [7:0]  rep_dx,
    input      [7:0]  rep_dy,
    input      [1:0]  btns,         // {right, left}

    input             rts,          // the port's RTS, active high
    output reg        rxd           // the line into the ВВ51: idle high
);

localparam [15:0] BIT = 16'd33750;  // 40.5 MHz / 1200

reg        tgl_d = 1'b0;
reg signed [8:0] acc_x = 9'd0, acc_y = 9'd0;
reg  [1:0] btn_sent = 2'd0;

// the bytes to send
reg  [7:0] b0, b1, b2;
reg  [1:0] nbytes = 2'd0;         // left in the report
reg  [7:0] sh;
reg  [3:0] bit_n = 4'd0;          // 0 idle; 1 start, 2..8 data, 9 stop
reg  [15:0] div = 16'd0;
reg  [20:0] wait_m = 21'd0;       // the M after RTS
reg        rts_d = 1'b0;
reg        send_m = 1'b0;

function signed [7:0] clip(input signed [8:0] v);
    clip = (v > 9'sd127) ? 8'sd127 : (v < -9'sd128) ? -8'sd128 : v[7:0];
endfunction

wire signed [7:0] nx = clip(acc_x + {rep_dx[7], rep_dx});
wire signed [7:0] ny = clip(acc_y + {rep_dy[7], rep_dy});
wire signed [7:0] dx = clip(acc_x);
wire signed [7:0] dy = clip(acc_y);
wire idle = (bit_n == 4'd0) && (nbytes == 2'd0);
wire something = (acc_x != 9'd0) || (acc_y != 9'd0) || (btns != btn_sent);

always @(posedge clk) begin
    tgl_d <= rep_tgl;
    rts_d <= rts;
    if (reset || !en) begin
        rxd <= 1'b1; bit_n <= 4'd0; nbytes <= 2'd0; acc_x <= 9'd0; acc_y <= 9'd0;
        btn_sent <= btns; send_m <= 1'b0; wait_m <= 21'd0;
    end else begin
        // gather
        if (rep_tgl != tgl_d) begin
            acc_x <= {nx[7], nx};
            acc_y <= {ny[7], ny};
        end
        // RTS up: the M, 14 ms later
        if (rts && !rts_d) wait_m <= 21'd567000;
        if (wait_m != 21'd0) begin
            wait_m <= wait_m - 21'd1;
            if (wait_m == 21'd1) send_m <= 1'b1;
        end

        // start a byte
        if (bit_n == 4'd0) begin
            if (nbytes != 2'd0) begin
                sh <= (nbytes == 2'd3) ? b0 : (nbytes == 2'd2) ? b1 : b2;
                nbytes <= nbytes - 2'd1;
                bit_n <= 4'd1; div <= 16'd0; rxd <= 1'b0;
            end else if (send_m) begin
                sh <= 8'h4D; send_m <= 1'b0;
                bit_n <= 4'd1; div <= 16'd0; rxd <= 1'b0;
            end else if (something) begin
                b0 <= {1'b0, 1'b1, btns[0], btns[1], dy[7:6], dx[7:6]};
                b1 <= {2'b00, dx[5:0]};
                b2 <= {2'b00, dy[5:0]};
                acc_x <= acc_x - {dx[7], dx};
                acc_y <= acc_y - {dy[7], dy};
                btn_sent <= btns;
                nbytes <= 2'd3;
            end
        end else begin
            if (div == BIT - 16'd1) begin
                div <= 16'd0;
                if (bit_n == 4'd8)      begin rxd <= 1'b1; bit_n <= 4'd9; end   // stop
                else if (bit_n == 4'd9) begin bit_n <= 4'd0; end
                else begin rxd <= sh[0]; sh <= {1'b0, sh[7:1]}; bit_n <= bit_n + 4'd1; end
            end else
                div <= div + 16'd1;
        end
    end
end

endmodule
