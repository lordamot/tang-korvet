/*
    sysctrl.v

    The system control target of the MCU link: the status the firmware
    checks at start (CMD 0, with the core id), the LEDs and colour it may
    set (1, 2), the buttons (3), the OSD's values (4), the interrupt
    control (5).  MiSTeryNano's, with this core's letters in CMD 4.

    The letters are the OSD's (mnano/menu.c, variables_korvet), and a
    menu value needs three edits: the letter in the form string, an entry
    in variables_korvet[], and a line here.

    CMD 6 is a write into the machine's RAM: address high, address low,
    then any number of data bytes, each a strobe on poke_stb (poke.v).
    CMD 7 is the debug window (memcheck.v): an offset, then bytes.
    CMD 8 is the ExtROM channel (extrom.v, mnano/extrom.c): a sub-command
    byte, then
      0  status: three bytes come back - bytes waiting, room to send,
         flags {0, 0, 0, 0, ctrl_fell, control, mode2, en}
      1  read: a count byte, then that many bytes come back
      2  write: bytes, as many as follow
      3  flush both FIFOs and the Control-fell flag
      4  load the phase-1 ROM: 256 bytes, from address 0
    As everywhere on this link the core answers one strobe behind: the
    byte set at a strobe is what the MCU clocks in during its next byte.
*/

module sysctrl (
  input             clk,
  input             reset,

  input             data_in_strobe,
  input             data_in_start,
  input [7:0]       data_in,
  output reg [7:0]  data_out,

  // interrupt interface
  output            int_out_n,
  input [7:0]       int_in,
  output reg [7:0]  int_ack,

  input [1:0]       buttons, // S0 and S1 buttons on Tang Nano 20k

  output reg [1:0]  leds, // two leds can be controlled from the MCU
  output reg [23:0] color, // a 24bit color to e.g. be used to drive the ws2812

  // values that can be configured by the user
  output reg [1:0]  system_reset,     // 'R' coldboot(3), reset(1), run(0)
  output reg [1:0]  system_volume,    // 'A' mute(0), 33%(1), 66%(2), 100%(3)
  output reg        system_beeper,    // 'b' 0 mute, 1 on
  output reg [1:0]  system_cpu,       // 'c' 0 ВМ80, 1 Z80, 2 Z80 at 5 MHz
  output reg        system_fdc,       // 'f' the floppy controller is in
  output reg        system_extrom,    // 'x' the ExtROM controller is on the connector
  output reg        system_ay,        // 'y' the AY module is on the connector
  output reg        system_mouse,     // 'M' the serial mouse is on the RS-232 port
  output reg        system_gzu48,     // 'm' 1 = one graphics page (48 KB), 0 = four (192 KB)
  output reg [3:0]  system_wprot,     // 'p' 'q' 'k' 'l' floppies A..D write-protected

  // CMD 6: a byte into the machine's RAM
  output reg        poke_stb,
  output reg [15:0] poke_adr,
  output reg [7:0]  poke_data,

  // CMD 7: the debug window (memcheck.v), 32 bytes
  input [255:0]     dbg,

  // CMD 8: the ExtROM channel (extrom.v)
  output reg        xr_rd,
  input  [7:0]      xr_rdata,
  output reg        xr_wr,
  output reg [7:0]  xr_wdata,
  output reg        xr_flush,
  output reg        xr_rom_wr,
  output reg [7:0]  xr_rom_adr,
  input  [7:0]      xr_rx_count,
  input  [7:0]      xr_tx_free,
  input  [7:0]      xr_flags
);

reg [3:0] state;
reg [7:0] command;
reg [7:0] id;
reg [7:0] xr_sub;
reg [7:0] xr_n;

// reverse data byte for rgb
wire [7:0] data_in_rev = { data_in[0], data_in[1], data_in[2], data_in[3],
                           data_in[4], data_in[5], data_in[6], data_in[7] };

reg coldboot = 1'b1;

// CMD 7's byte index: the offset plus the strobes since it, wrapping
wire [4:0] dbg_ix = id[4:0] + {1'b0, state} - 5'd1;

assign int_out_n = (int_in != 8'h00 || coldboot)?1'b0:1'b1;

always @(posedge clk) begin
   if(reset) begin
      state <= 4'd0;
      leds <= 2'b00;        // after reset leds are off
      color <= 24'h000000;  // color black -> rgb led off

      int_ack <= 8'h00;
      coldboot = 1'b1;      // reset is actually the power-on-reset

      // the OSD's defaults (menu.c, variables_korvet), until the MCU says
      system_reset  <= 2'b00;
      system_volume <= 2'b01;
      system_beeper <= 1'b1;
      system_cpu    <= 2'b00;
      system_fdc    <= 1'b1;
      system_extrom <= 1'b0;
      system_ay     <= 1'b0;
      system_mouse  <= 1'b1;
      system_gzu48  <= 1'b0;
      system_wprot  <= 4'b0000;
      poke_stb <= 1'b0;
      poke_adr <= 16'd0;
      xr_rd <= 1'b0; xr_wr <= 1'b0; xr_flush <= 1'b0; xr_rom_wr <= 1'b0; xr_rom_adr <= 8'd0;
      xr_sub <= 8'd0; xr_n <= 8'd0;
   end else begin
      int_ack <= 8'h00;
      poke_stb <= 1'b0;
      xr_rd <= 1'b0; xr_wr <= 1'b0; xr_flush <= 1'b0; xr_rom_wr <= 1'b0;
      if(poke_stb) poke_adr <= poke_adr + 16'd1;   // the clock after a byte
      if(xr_rom_wr) xr_rom_adr <= xr_rom_adr + 8'd1;

      // iack bit 0 acknowledges the coldboot notification
      if(int_ack[0]) coldboot <= 1'b0;

      if(data_in_strobe) begin
        if(data_in_start) begin
            state <= 4'd1;
            command <= data_in;
        end else if(state != 4'd0) begin
            if(state != 4'd15) state <= state + 4'd1;

            // CMD 0: status data
            if(command == 8'd0) begin
                if(state == 4'd1) data_out <= 8'h5c;
                if(state == 4'd2) data_out <= 8'h42;
                if(state == 4'd3) data_out <= 8'h08;   // core id 8 = Korvet (mnano/sysctrl.h)
            end

            // CMD 1: there are two MCU controlled LEDs
            if(command == 8'd1) begin
                if(state == 4'd1) leds <= data_in[1:0];
            end

            // CMD 2: a 24 color value to be mapped e.g. onto the ws2812
            if(command == 8'd2) begin
                if(state == 4'd1) color[15: 8] <= data_in_rev;
                if(state == 4'd2) color[ 7: 0] <= data_in_rev;
                if(state == 4'd3) color[23:16] <= data_in_rev;
            end

            // CMD 3: return button state
            if(command == 8'd3) begin
                data_out <= { 6'b000000, buttons };
            end

            // CMD 4: config values (e.g. set by user via OSD)
            if(command == 8'd4) begin
                if(state == 4'd1) id <= data_in;

                if(state == 4'd2) begin
                    if(id == "R") system_reset   <= data_in[1:0];
                    if(id == "A") system_volume  <= data_in[1:0];
                    if(id == "b") system_beeper  <= data_in[0];
                    if(id == "c") system_cpu     <= data_in[1:0];
                    if(id == "f") system_fdc     <= data_in[0];
                    if(id == "x") system_extrom  <= data_in[0];
                    if(id == "y") system_ay      <= data_in[0];
                    if(id == "M") system_mouse   <= data_in[0];
                    if(id == "m") system_gzu48   <= data_in[0];
                    if(id == "p") system_wprot[0] <= data_in[0];
                    if(id == "q") system_wprot[1] <= data_in[0];
                    if(id == "k") system_wprot[2] <= data_in[0];
                    if(id == "l") system_wprot[3] <= data_in[0];
                end
            end

            // CMD 6: a write into RAM - address, then the bytes
            if(command == 8'd6) begin
                if(state == 4'd1) poke_adr[15:8] <= data_in;
                if(state == 4'd2) poke_adr[7:0]  <= data_in;
                if(state >= 4'd3) begin poke_data <= data_in; poke_stb <= 1'b1; end
            end

            // CMD 7: the debug window - the offset, then the bytes
            if(command == 8'd7) begin
                if(state == 4'd1) begin
                    id <= data_in;
                    data_out <= dbg[8*data_in[4:0] +: 8];
                end else
                    data_out <= dbg[8*dbg_ix +: 8];
            end

            // CMD 8: the ExtROM channel
            if(command == 8'd8) begin
                if(state == 4'd1) begin
                    xr_sub <= data_in;
                    if(data_in == 8'd0) data_out <= xr_rx_count;
                    if(data_in == 8'd3) xr_flush <= 1'b1;
                    if(data_in == 8'd4) xr_rom_adr <= 8'd0;
                end else begin
                    case (xr_sub)
                    8'd0: begin
                        if(state == 4'd2) data_out <= xr_tx_free;
                        if(state == 4'd3) data_out <= xr_flags;
                    end
                    8'd1: begin
                        if(state == 4'd2) begin
                            xr_n <= data_in;
                            if(data_in != 8'd0) begin data_out <= xr_rdata; xr_rd <= 1'b1; xr_n <= data_in - 8'd1; end
                        end else if(xr_n != 8'd0) begin
                            data_out <= xr_rdata; xr_rd <= 1'b1; xr_n <= xr_n - 8'd1;
                        end
                    end
                    8'd2: begin xr_wdata <= data_in; xr_wr <= 1'b1; end
                    8'd4: begin xr_wdata <= data_in; xr_rom_wr <= 1'b1; end
                    default: ;
                    endcase
                end
            end

            // CMD 5: interrupt control
            if(command == 8'd5) begin
                if(state == 4'd1) int_ack <= data_in;
                data_out <= { int_in[7:1], coldboot };
            end
         end
      end
   end
end

endmodule
