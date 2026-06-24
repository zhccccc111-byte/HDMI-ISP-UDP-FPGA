`timescale 1ns / 1ps

// Fixed-latency 8-stage byte shift register replacement for the legacy IP.
module udp_shift_register (
    input  wire [7:0] din,
    input  wire       clk,
    input  wire       rst,
    output wire [7:0] dout
);

    reg [7:0] stage [0:7];
    integer i;

    assign dout = stage[7];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1)
                stage[i] <= 8'd0;
        end else begin
            stage[0] <= din;
            for (i = 1; i < 8; i = i + 1)
                stage[i] <= stage[i - 1];
        end
    end

endmodule
