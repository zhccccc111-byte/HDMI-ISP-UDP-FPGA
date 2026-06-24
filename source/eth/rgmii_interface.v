`timescale 1ns / 1ps

`define UD #1

module rgmii_interface(
    input        rst,
    output       rgmii_clk,
    input        rgmii_clk_90p,

    input        mac_tx_data_valid,
    input [7:0]  mac_tx_data,

    output reg       mac_rx_error,
    output reg       mac_rx_data_valid,
    output reg [7:0] mac_rx_data,

    input        rgmii_rxc,
    input        rgmii_rx_ctl,
    input [3:0]  rgmii_rxd,

    output       rgmii_txc,
    output       rgmii_tx_ctl,
    output [3:0] rgmii_txd
);

//=============================================================
//  RGMII TX
//=============================================================
    wire       rgmii_txc_obuf;
    wire       rgmii_tx_ctl_obuf;
    wire [3:0] rgmii_txd_obuf;

    generate
        genvar i;
        for (i = 0; i < 4; i = i + 1) begin : rgmii_tx_data
            GTP_ODDR_E1 #(
                .GRS_EN    ("TRUE"),
                .ODDR_MODE ("SAME_EDGE"),
                .RS_TYPE   ("ASYNC_RESET")
            ) rgmii_txd_ddr (
                .Q   (rgmii_txd_obuf[i]),
                .CE  (1'b1),
                .CLK (rgmii_clk),
                .D0  (mac_tx_data[i]),
                .D1  (mac_tx_data[i + 4]),
                .RS  (1'b0)
            );

            GTP_OUTBUF #(
                .IOSTANDARD     ("LVCMOS33"),
                .SLEW_RATE      ("FAST"),
                .DRIVE_STRENGTH ("4")
            ) u_rgmii_txd_obuf (
                .I (rgmii_txd_obuf[i]),
                .O (rgmii_txd[i])
            );
        end
    endgenerate

    GTP_ODDR_E1 #(
        .GRS_EN    ("TRUE"),
        .ODDR_MODE ("SAME_EDGE"),
        .RS_TYPE   ("ASYNC_RESET")
    ) rgmii_tdv_ddr (
        .Q   (rgmii_tx_ctl_obuf),
        .CE  (1'b1),
        .CLK (rgmii_clk),
        .D0  (mac_tx_data_valid),
        .D1  (mac_tx_data_valid ^ 1'b0),
        .RS  (1'b0)
    );

    GTP_OUTBUF #(
        .IOSTANDARD     ("LVCMOS33"),
        .SLEW_RATE      ("FAST"),
        .DRIVE_STRENGTH ("4")
    ) u_rgmii_tx_ctl_obuf (
        .I (rgmii_tx_ctl_obuf),
        .O (rgmii_tx_ctl)
    );

    GTP_ODDR_E1 #(
        .GRS_EN    ("TRUE"),
        .ODDR_MODE ("SAME_EDGE"),
        .RS_TYPE   ("ASYNC_RESET")
    ) rgmii_txc_ddr (
        .Q   (rgmii_txc_obuf),
        .CE  (1'b1),
        .CLK (rgmii_clk),
        .D0  (1'b1),
        .D1  (1'b0),
        .RS  (1'b0)
    );

    wire [7:0] delay_step_c;
    wire [7:0] delay_step_clk;
    wire       rgmii_txc_dly;

    assign delay_step_c   = 8'd100;
    assign delay_step_clk = ((delay_step_c >> 1) ^ delay_step_c);

    GTP_IODELAY_E2 #(
        .DELAY_STEP_SEL   ("PORT"),
        .DELAY_STEP_VALUE ()
    ) tx_clk_delay (
        .DI         (rgmii_txc_obuf),
        .DELAY_SEL  (1'b1),
        .DELAY_STEP (delay_step_clk),
        .DO         (rgmii_txc_dly),
        .EN_N       (1'b0)
    );

    GTP_OUTBUF #(
        .IOSTANDARD     ("LVCMOS33"),
        .SLEW_RATE      ("FAST"),
        .DRIVE_STRENGTH ("4")
    ) u_rgmii_txc_obuf (
        .I (rgmii_txc_dly),
        .O (rgmii_txc)
    );

//=============================================================
//  RGMII RX
//=============================================================
    wire        rgmii_rx_ctl_ibuf;
    wire [3:0]  rgmii_rxd_ibuf;
    wire [7:0]  delay_step_b;
    wire [7:0]  delay_step_gray;
    wire        rgmii_rx_ctl_delay;
    wire        gmii_ctl;
    wire        rgmii_rx_valid_xor_error;
    wire [3:0]  rgmii_rxd_delay;
    wire [7:0]  gmii_rxd;

    parameter DELAY_STEP = 8'hE6;

    assign delay_step_b    = 8'd247;
    assign delay_step_gray = ((delay_step_b >> 1) ^ delay_step_b);

    GTP_CLKBUFG GTP_CLKBUFG_RXSHFT(
        .CLKIN  (rgmii_rxc),
        .CLKOUT (rgmii_clk)
    );

    GTP_INBUF #(
        .IOSTANDARD ("LVCMOS33"),
        .TERM_DDR   ()
    ) u_rgmii_rx_ctl_ibuf (
        .O (rgmii_rx_ctl_ibuf),
        .I (rgmii_rx_ctl)
    );

    GTP_IODELAY_E2 #(
        .DELAY_STEP_VALUE (DELAY_STEP),
        .DELAY_STEP_SEL   ("PORT"),
        .TDELAY_EN        ("FALSE")
    ) delay_rgmii_rx_ctl (
        .DELAY_STEP (delay_step_gray),
        .DO         (rgmii_rx_ctl_delay),
        .DELAY_SEL  (1'b1),
        .DI         (rgmii_rx_ctl_ibuf),
        .EN_N       (1'b0)
    );

    GTP_IDDR_E1 #(
        .GRS_EN    ("TRUE"),
        .IDDR_MODE ("SAME_PIPELINED"),
        .RS_TYPE   ("SYNC_RESET")
    ) rgmii_rx_ctl_in (
        .Q0  (gmii_ctl),
        .Q1  (rgmii_rx_valid_xor_error),
        .CE  (1'b1),
        .CLK (rgmii_clk),
        .D   (rgmii_rx_ctl_delay),
        .RS  (1'b0)
    );

    always @(posedge rgmii_clk) begin
        mac_rx_data       <= gmii_rxd;
        mac_rx_data_valid <= gmii_ctl;
        mac_rx_error      <= gmii_ctl ^ rgmii_rx_valid_xor_error;
    end

    generate
        genvar j;
        for (j = 0; j < 4; j = j + 1) begin : rgmii_rx_data
            GTP_INBUF #(
                .IOSTANDARD ("LVCMOS33"),
                .TERM_DDR   ()
            ) u_rgmii_rxd_ibuf (
                .O (rgmii_rxd_ibuf[j]),
                .I (rgmii_rxd[j])
            );

            GTP_IODELAY_E2 #(
                .DELAY_STEP_VALUE (DELAY_STEP),
                .DELAY_STEP_SEL   ("PORT"),
                .TDELAY_EN        ("FALSE")
            ) delay_rgmii_rxd (
                .DELAY_STEP (delay_step_gray),
                .DO         (rgmii_rxd_delay[j]),
                .DELAY_SEL  (1'b1),
                .DI         (rgmii_rxd_ibuf[j]),
                .EN_N       (1'b0)
            );

            GTP_IDDR_E1 #(
                .GRS_EN    ("TRUE"),
                .IDDR_MODE ("SAME_PIPELINED"),
                .RS_TYPE   ("ASYNC_RESET")
            ) rgmii_rx_data_in (
                .Q0  (gmii_rxd[j]),
                .Q1  (gmii_rxd[j + 4]),
                .CE  (1'b1),
                .CLK (rgmii_clk),
                .D   (rgmii_rxd_delay[j]),
                .RS  (1'b0)
            );
        end
    endgenerate

endmodule
