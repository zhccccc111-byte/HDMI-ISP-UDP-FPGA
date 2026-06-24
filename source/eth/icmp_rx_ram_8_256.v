`timescale 1ns / 1ps

// Simple dual-port RAM replacement for the legacy 50K ICMP receive RAM IP.
module icmp_rx_ram_8_256 (
    input  wire [7:0]  wr_data,
    input  wire [10:0] wr_addr,
    input  wire        wr_en,
    input  wire        wr_clk,
    input  wire        wr_rst,
    output wire [7:0]  rd_data,
    input  wire [10:0] rd_addr,
    input  wire        rd_clk,
    input  wire        rd_rst
);

    reg [7:0] mem [0:(1 << 11) - 1];
    reg [7:0] rd_data_r = 8'd0;

    assign rd_data = rd_data_r;

    always @(posedge wr_clk) begin
        if (!wr_rst && wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        if (rd_rst)
            rd_data_r <= 8'd0;
        else
            rd_data_r <= mem[rd_addr];
    end

endmodule
