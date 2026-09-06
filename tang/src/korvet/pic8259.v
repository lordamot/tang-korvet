`timescale 1ns / 1ps
//========================================================================
// pic8259.v - the КР580ВН59 interrupt controller, in its 8080 mode.
//
// Eight requests, fixed priority (0 highest), edge or level triggered by
// ICW1's LTIM, a mask, and the three-byte CALL it hands the processor:
// CDh in the first acknowledge cycle, then the low byte - ICW1's A7..A5
// (A7, A6 with an interval of 8) over the level - and ICW2 as the high
// byte.  Initialisation as the datasheet: ICW1 at A0 = 0 with bit 4 set,
// ICW2, ICW3 unless SNGL, ICW4 if IC4 (AEOI is honoured; the rest of it
// is ignored); then OCW1 (A0 = 1) is the mask, OCW2 the EOIs (the
// rotating forms are taken as their plain ones: the Корвет's software
// uses fixed priority), OCW3 selects what A0 = 0 reads back - IRR or
// ISR - and the poll command.
//
// On the Корвет: 0 the expansion connector, 1 and 2 the ВВ51 #1's
// receiver and transmitter, 3 the ВВ51 #2 (network) receiver, 4 the
// frame (VBL's end), 5 the timer's counter 2, 6 the printer, 7 the
// floppy motor's time-out.  The ExtROM's Control comes in on level 0
// through its jumper (the connector's pin is named IRQ7, but the ОПТС
// tests bit 0 of IRR after raising Control, and so does Erokhin's
// emulator patch); that read is why OCW3 is here.
//
// A request bit follows its line: an edge (or a level, by LTIM) sets it
// and the line going low clears it, as the datasheet has it (a request
// withdrawn before the acknowledge is gone, not held) and as Emu80's
// Pic8259 does.  So a request has to be a level held until it is served:
// VBL's blanking, the timer's output, the ВВ51s' ready lines, the motor
// one-shot's idle output.
//========================================================================
module pic8259 (
    input             clk,
    input             reset,

    input             wr,
    input             rd,
    input             a0,
    input      [7:0]  wdata,
    output reg [7:0]  rdata,

    input      [7:0]  ir,           // the requests, active high

    output            int_out,      // to the CPU
    input             inta_stb,     // one clock, each acknowledge cycle
    input      [1:0]  inta_n,       // 0 the opcode, 1 low byte, 2 high byte
    output reg [7:0]  inta_data
);

reg [7:0] irr = 8'd0, isr = 8'd0, imr = 8'd0;
reg [7:0] icw1 = 8'd0, icw2 = 8'd0;
reg       aeoi = 1'b0;
reg [1:0] init = 2'd0;              // 0 running, 1 wants ICW2, 2 wants ICW3, 3 wants ICW4
reg       read_isr = 1'b0;
reg       poll = 1'b0;
reg [7:0] ir_d = 8'd0;
reg [2:0] level = 3'd0;             // the request being acknowledged

wire ltim = icw1[3];
wire adi4 = icw1[2];
wire sngl = icw1[1];
wire ic4  = icw1[0];

// the highest pending request that outranks everything in service
wire [7:0] pend = irr & ~imr;
reg  [2:0] top;
reg        any;
integer i;
always @(*) begin
    any = 1'b0; top = 3'd7;
    for (i = 7; i >= 0; i = i - 1)
        if (pend[i]) begin any = 1'b1; top = i[2:0]; end
end
reg [2:0] top_isr;
reg       any_isr;
always @(*) begin
    any_isr = 1'b0; top_isr = 3'd7;
    for (i = 7; i >= 0; i = i - 1)
        if (isr[i]) begin any_isr = 1'b1; top_isr = i[2:0]; end
end
assign int_out = any && (!any_isr || top < top_isr);

wire [7:0] low_byte = adi4 ? {icw1[7:5], level, 2'b00} : {icw1[7:6], level, 3'b000};

always @(posedge clk) begin
    ir_d <= ir;
    if (reset) begin
        irr <= 8'd0; isr <= 8'd0; imr <= 8'd0; icw1 <= 8'd0; icw2 <= 8'd0;
        aeoi <= 1'b0; init <= 2'd0; read_isr <= 1'b0; poll <= 1'b0; level <= 3'd0;
        inta_data <= 8'hCD;
    end else begin
        // the requests: an edge sets, a level holds, the line going low clears
        for (i = 0; i < 8; i = i + 1) begin
            if (ltim) irr[i] <= ir[i];
            else if (ir[i] && !ir_d[i]) irr[i] <= 1'b1;
            else if (!ir[i]) irr[i] <= 1'b0;
        end

        if (wr) begin
            if (!a0 && wdata[4]) begin                     // ICW1
                icw1 <= wdata; imr <= 8'd0; isr <= 8'd0; irr <= 8'd0;
                aeoi <= 1'b0; read_isr <= 1'b0;
                init <= 2'd1;
            end else if (init == 2'd1 && a0) begin          // ICW2
                icw2 <= wdata;
                init <= !sngl ? 2'd2 : (ic4 ? 2'd3 : 2'd0);
            end else if (init == 2'd2 && a0) begin          // ICW3
                init <= ic4 ? 2'd3 : 2'd0;
            end else if (init == 2'd3 && a0) begin          // ICW4
                aeoi <= wdata[1];
                init <= 2'd0;
            end else if (a0) begin                          // OCW1
                imr <= wdata;
            end else if (wdata[3]) begin                    // OCW3
                if (wdata[1]) read_isr <= wdata[0];
                if (wdata[2]) poll <= 1'b1;
            end else begin                                  // OCW2
                case (wdata[7:5])
                    3'b001, 3'b101: begin                   // non-specific EOI
                        if (any_isr) isr[top_isr] <= 1'b0;
                    end
                    3'b011, 3'b111: isr[wdata[2:0]] <= 1'b0; // specific EOI
                    default: ;
                endcase
            end
        end

        if (rd) begin
            if (poll) begin
                rdata <= {any, 4'd0, top};
                poll  <= 1'b0;
                if (any) begin isr[top] <= 1'b1; if (!ltim) irr[top] <= 1'b0; end
            end else if (a0)
                rdata <= imr;
            else
                rdata <= read_isr ? isr : irr;
        end

        // the acknowledge: the first cycle picks the winner
        if (inta_stb) begin
            case (inta_n)
                2'd0: begin
                    level <= any ? top : 3'd7;
                    if (any) begin
                        isr[top] <= 1'b1;
                        if (!ltim) irr[top] <= 1'b0;
                    end
                    inta_data <= 8'hCD;
                end
                2'd1: inta_data <= low_byte;
                default: begin
                    inta_data <= icw2;
                    if (aeoi) isr[level] <= 1'b0;
                end
            endcase
        end
    end
end

endmodule
