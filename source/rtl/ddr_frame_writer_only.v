`timescale 1ns / 1ps

module ddr_frame_writer_only #(
    parameter MEM_ROW_WIDTH    = 15,
    parameter MEM_COLUMN_WIDTH = 10,
    parameter MEM_BANK_WIDTH   = 3,
    parameter CTRL_ADDR_WIDTH  = MEM_ROW_WIDTH + MEM_COLUMN_WIDTH + MEM_BANK_WIDTH,
    parameter MEM_DQ_WIDTH     = 32,
    parameter H_NUM            = 640,
    parameter V_NUM            = 360,
    parameter PIX_WIDTH        = 16,
    parameter LINE_ADDR_WIDTH  = 22,
    parameter FRAME_CNT_WIDTH  = CTRL_ADDR_WIDTH - LINE_ADDR_WIDTH
) (
    input                         vin_clk,
    input                         wr_fsync,
    input                         wr_en,
    input  [PIX_WIDTH-1:0]        wr_data,
    input                         ddr_clk,
    input                         ddr_rstn,

    output [FRAME_CNT_WIDTH-1:0]  frame_wcnt,
    output                        frame_wirq,

    output [CTRL_ADDR_WIDTH-1:0]  axi_awaddr,
    output [3:0]                  axi_awid,
    output [3:0]                  axi_awlen,
    output [2:0]                  axi_awsize,
    output [1:0]                  axi_awburst,
    input                         axi_awready,
    output                        axi_awvalid,
    output [MEM_DQ_WIDTH*8-1:0]   axi_wdata,
    output [MEM_DQ_WIDTH-1:0]     axi_wstrb,
    input                         axi_wlast,
    output                        axi_wvalid,
    input                         axi_wready
);

    localparam LEN_WIDTH = 32;

    wire                        ddr_wreq;
    wire [CTRL_ADDR_WIDTH-1:0]  ddr_waddr;
    wire [LEN_WIDTH-1:0]        ddr_wr_len;
    wire                        ddr_wrdy;
    wire                        ddr_wdone;
    wire [8*MEM_DQ_WIDTH-1:0]   ddr_wdata;
    wire                        ddr_wdata_req;

    wire                        wr_en_int;
    wire [CTRL_ADDR_WIDTH-1:0]  wr_addr_int;
    wire [3:0]                  wr_id_int;
    wire [3:0]                  wr_len_int;
    wire                        wr_data_en_int;
    wire [MEM_DQ_WIDTH*8-1:0]   wr_data_int;
    wire                        wr_bac_int;

    wr_buf #(
        .ADDR_WIDTH      ( CTRL_ADDR_WIDTH ),
        .ADDR_OFFSET     ( 32'd0           ),
        .H_NUM           ( H_NUM           ),
        .V_NUM           ( V_NUM           ),
        .DQ_WIDTH        ( MEM_DQ_WIDTH    ),
        .LEN_WIDTH       ( LEN_WIDTH       ),
        .PIX_WIDTH       ( PIX_WIDTH       ),
        .LINE_ADDR_WIDTH ( LINE_ADDR_WIDTH ),
        .FRAME_CNT_WIDTH ( FRAME_CNT_WIDTH )
    ) u_wr_buf (
        .ddr_clk       ( ddr_clk       ),
        .ddr_rstn      ( ddr_rstn      ),
        .wr_clk        ( vin_clk       ),
        .wr_fsync      ( wr_fsync      ),
        .wr_en         ( wr_en         ),
        .wr_data       ( wr_data       ),
        .rd_bac        ( 1'b0          ),
        .ddr_wreq      ( ddr_wreq      ),
        .ddr_waddr     ( ddr_waddr     ),
        .ddr_wr_len    ( ddr_wr_len    ),
        .ddr_wrdy      ( ddr_wrdy      ),
        .ddr_wdone     ( ddr_wdone     ),
        .ddr_wdata     ( ddr_wdata     ),
        .ddr_wdata_req ( ddr_wdata_req ),
        .frame_wcnt    ( frame_wcnt    ),
        .frame_wirq    ( frame_wirq    )
    );

    wr_cmd_trans #(
        .CTRL_ADDR_WIDTH ( CTRL_ADDR_WIDTH ),
        .MEM_DQ_WIDTH    ( MEM_DQ_WIDTH    )
    ) u_wr_cmd_trans (
        .clk          ( ddr_clk        ),
        .rstn         ( ddr_rstn       ),
        .wr_cmd_en    ( ddr_wreq       ),
        .wr_cmd_addr  ( ddr_waddr      ),
        .wr_cmd_len   ( ddr_wr_len     ),
        .wr_cmd_ready ( ddr_wrdy       ),
        .wr_cmd_done  ( ddr_wdone      ),
        .wr_bac       ( wr_bac_int     ),
        .wr_ctrl_data ( ddr_wdata      ),
        .wr_data_re   ( ddr_wdata_req  ),
        .wr_en        ( wr_en_int      ),
        .wr_addr      ( wr_addr_int    ),
        .wr_id        ( wr_id_int      ),
        .wr_len       ( wr_len_int     ),
        .wr_data_en   ( wr_data_en_int ),
        .wr_data      ( wr_data_int    ),
        .wr_ready     ( axi_wready     ),
        .wr_done      ( axi_wlast      ),
        .rd_cmd_en    ( 1'b0           ),
        .rd_cmd_addr  ( {CTRL_ADDR_WIDTH{1'b0}} ),
        .rd_cmd_len   ( 32'd0          ),
        .rd_cmd_ready (                ),
        .rd_cmd_done  (                ),
        .read_en      ( 1'b0           ),
        .rd_en        (                ),
        .rd_addr      (                ),
        .rd_id        (                ),
        .rd_len       (                ),
        .rd_done_p    ( 1'b0           )
    );

    wr_ctrl #(
        .CTRL_ADDR_WIDTH ( CTRL_ADDR_WIDTH ),
        .MEM_DQ_WIDTH    ( MEM_DQ_WIDTH    )
    ) u_wr_ctrl (
        .clk          ( ddr_clk        ),
        .rst_n        ( ddr_rstn       ),
        .wr_en        ( wr_en_int      ),
        .wr_addr      ( wr_addr_int    ),
        .wr_id        ( wr_id_int      ),
        .wr_len       ( wr_len_int     ),
        .wr_cmd_done  (                ),
        .wr_ready     (                ),
        .wr_data_en   ( wr_data_en_int ),
        .wr_data      ( wr_data_int    ),
        .wr_bac       ( wr_bac_int     ),
        .axi_awaddr   ( axi_awaddr     ),
        .axi_awid     ( axi_awid       ),
        .axi_awlen    ( axi_awlen      ),
        .axi_awsize   ( axi_awsize     ),
        .axi_awburst  ( axi_awburst    ),
        .axi_awready  ( axi_awready    ),
        .axi_awvalid  ( axi_awvalid    ),
        .axi_wdata    ( axi_wdata      ),
        .axi_wstrb    ( axi_wstrb      ),
        .axi_wlast    ( axi_wlast      ),
        .axi_wvalid   ( axi_wvalid     ),
        .axi_wready   ( axi_wready     ),
        .axi_bid      ( 4'd0           ),
        .axi_bresp    ( 2'd0           ),
        .axi_bvalid   ( 1'b0           ),
        .axi_bready   (                ),
        .test_wr_state(                )
    );

endmodule
