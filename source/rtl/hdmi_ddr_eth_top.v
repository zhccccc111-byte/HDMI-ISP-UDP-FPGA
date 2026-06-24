`timescale 1ns / 1ps

module hdmi_ddr_eth_top #(
    parameter MEM_ROW_ADDR_WIDTH = 15,
    parameter MEM_COL_ADDR_WIDTH = 10,
    parameter MEM_BADDR_WIDTH    = 3,
    parameter MEM_DQ_WIDTH       = 32,
    parameter MEM_DQS_WIDTH      = 32/8,
    parameter CTRL_ADDR_WIDTH    = MEM_ROW_ADDR_WIDTH + MEM_BADDR_WIDTH + MEM_COL_ADDR_WIDTH,
    parameter IMG_WIDTH          = 640,
    parameter IMG_HEIGHT         = 640,
    parameter SRC_IMG_HEIGHT     = 360,
    parameter FRAME_SLOT_ADDR    = 28'd4194304,
    parameter LINE_ADDR_STEP     = 28'd320,
    parameter BURST_ADDR_STEP    = 8'd64,
    parameter TOTAL_FRAMES       = 2,
    parameter OUTPUT_FRAME_PERIOD_CNT = 32'd4_166_667,
    parameter LOCAL_MAC          = 48'ha0_b1_c2_d3_e1_e1,
    parameter LOCAL_IP           = 32'hC0_A8_01_0B,
    parameter LOCL_PORT          = 16'h1F90,
    parameter DEST_MAC           = 48'h9A_CB_4C_37_BF_04,
    parameter DEST_IP            = 32'hC0_A8_01_69,
    parameter DEST_PORT          = 16'h1F90,
    parameter FIXED_DEST_MAC_EN  = 1'b1
)(
    input                                sys_clk,
    input                                clk_p,
    input                                clk_n,
    input                                rst_in,

    output                               mem_rst_n,
    output                               mem_ck,
    output                               mem_ck_n,
    output                               mem_cke,
    output                               mem_cs_n,
    output                               mem_ras_n,
    output                               mem_cas_n,
    output                               mem_we_n,
    output                               mem_odt,
    output      [MEM_ROW_ADDR_WIDTH-1:0] mem_a,
    output      [MEM_BADDR_WIDTH-1:0]    mem_ba,
    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs,
    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs_n,
    inout       [MEM_DQ_WIDTH-1:0]       mem_dq,
    output      [MEM_DQ_WIDTH/8-1:0]     mem_dm,
    output reg                           heart_beat_led,
    output                               ddr_init_done,
    output                               init_over_rx,

    output                               hd_scl,
    inout                                hd_sda,
    output                               hdmi_int_led,

    input                                pixclk_in,
    input                                vs_in,
    input                                hs_in,
    input                                de_in,
    input      [7:0]                     r_in,
    input      [7:0]                     g_in,
    input      [7:0]                     b_in,

    input                                rgmii_rxc,
    input                                rgmii_rx_ctl,
    input      [3:0]                     rgmii_rxd,
    output                               phy_rstn,
    output                               rgmii_txc,
    output                               rgmii_tx_ctl,
    output     [3:0]                     rgmii_txd,
    output     [7:0]                     led
);

localparam MEM_DM_WIDTH = MEM_DQ_WIDTH / 8;
localparam AXI_DATA_WIDTH = MEM_DQ_WIDTH * 8;
localparam AXI_STRB_WIDTH = MEM_DQ_WIDTH;
localparam DDR_BEATS_PER_BURST = 8;
localparam HEARTBEAT_1S = 27'd125_000_000;
localparam [2:0] INPUT_MODE_HDMI                  = 3'd0;
localparam [2:0] INPUT_MODE_COLOR_BAR_SYS         = 3'd1;
localparam [2:0] INPUT_MODE_COLOR_BAR_HDMI_TIMING = 3'd2;
localparam [2:0] INPUT_MODE_COLOR_BAR_RAW_TIMING  = 3'd3;
localparam [2:0] INPUT_MODE_COLOR_BAR_PIXCLK      = 3'd4;
localparam [2:0] TEST_INPUT_MODE                  = INPUT_MODE_HDMI;
localparam integer TOP_PAD_LINES  = (IMG_HEIGHT - SRC_IMG_HEIGHT) / 2;
localparam integer ACTIVE_END_LINE = TOP_PAD_LINES + SRC_IMG_HEIGHT;
localparam [22:0] LED_HOLD_CNT = 23'd5_000_000;

reg  [15:0] rstn_1ms = 16'd0;
reg  [26:0] heartbeat_cnt = 27'd0;
reg  [22:0] led0_cnt = 23'd0;
reg  [22:0] led1_cnt = 23'd0;
reg  [22:0] led2_cnt = 23'd0;
reg  [22:0] led3_cnt = 23'd0;
reg  [22:0] led4_cnt = 23'd0;
reg  [22:0] led5_cnt = 23'd0;
reg  [22:0] led6_cnt = 23'd0;
reg  [22:0] led7_cnt = 23'd0;
reg  [7:0]  led_reg = 8'd0;

wire locked_27m = 1'b1;
wire cfg_clk = sys_clk;
wire clk_125mhz;
wire rx_init_done;
wire pll_lock;
wire core_clk;
wire core_clk_rst_n;
wire rgmii_clk;
wire rgmii_clk_90p;
wire rgmii_clk_lock;
wire rgmii_clk_rst_n;

wire [CTRL_ADDR_WIDTH-1:0] axi_awaddr;
wire [3:0]                 axi_awid;
wire [3:0]                 axi_awlen;
wire [2:0]                 axi_awsize;
wire [1:0]                 axi_awburst;
wire                       axi_awready;
wire                       axi_awvalid;
wire [AXI_DATA_WIDTH-1:0]  axi_wdata;
wire [AXI_STRB_WIDTH-1:0]  axi_wstrb;
wire                       axi_wvalid;
wire                       axi_wready;
wire                       axi_wlast;

wire [CTRL_ADDR_WIDTH-1:0] axi_araddr;
wire                       axi_aruser_ap;
wire [3:0]                 axi_aruser_id;
wire [3:0]                 axi_arlen;
wire                       axi_arready;
wire                       axi_arvalid;
wire [AXI_DATA_WIDTH-1:0]  axi_rdata;
wire [3:0]                 axi_rid;
wire                       axi_rlast;
wire                       axi_rvalid;

wire [5:0]                 frame_wcnt;
wire                       frame_wirq;
reg                        latest_frame_valid = 1'b0;
reg  [31:0]               latest_frame_id = 32'd0;
reg  [31:0]               latest_frame_seq = 32'd0;
reg                        latest_frame_slot = 1'b0;

wire                       gamma_de;
wire [7:0]                 gamma_data_r;
wire [7:0]                 gamma_data_g;
wire [7:0]                 gamma_data_b;
wire                       gauss_vs;
wire                       gauss_de;
wire [7:0]                 gauss_r;
wire [7:0]                 gauss_g;
wire [7:0]                 gauss_b;
wire                       csc_de;
wire                       csc_vs;
wire [7:0]                 csc_y;
wire [7:0]                 csc_u;
wire [7:0]                 csc_v;
reg                        csc_de_r = 1'b0;
reg                        csc_vs_r = 1'b0;
reg  [7:0]                 csc_y_r  = 8'd0;
reg  [7:0]                 csc_u_r  = 8'd0;
reg  [7:0]                 csc_v_r  = 8'd0;
wire                       ee_de;
wire                       ee_vs;
wire [7:0]                 ee_y;
wire [7:0]                 ee_u;
wire [7:0]                 ee_v;
wire                       occ_de;
wire                       occ_vs;
wire [7:0]                 occ_r;
wire [7:0]                 occ_g;
wire [7:0]                 occ_b;
wire                       process_vs;
wire                       process_de;
wire [7:0]                 sc_r;
wire [7:0]                 sc_g;
wire [7:0]                 sc_b;
wire [9:0]                 sc_x;
wire [8:0]                 sc_y;
wire                       raw_process_vs;
wire                       raw_process_de;
wire [7:0]                 raw_sc_r;
wire [7:0]                 raw_sc_g;
wire [7:0]                 raw_sc_b;
wire [9:0]                 raw_sc_x;
wire [8:0]                 raw_sc_y;
wire [15:0]                write_data;
wire                       test_src_vs;
wire                       test_src_de;
wire [15:0]                test_src_data;
wire                       test_pixclk_vs;
wire                       test_pixclk_de;
wire [15:0]                test_pixclk_data;
wire [15:0]                test_hdmi_timing_data;
wire [15:0]                test_raw_timing_data;
wire                       write_src_clk;
wire                       write_src_vs;
wire                       write_src_de;
wire [15:0]                write_src_data;
wire                       write_base_vs;
wire                       write_base_de;
wire [15:0]                write_base_data;
wire                       use_hdmi_timing_gate;
wire                       write_timed_vs;
wire                       write_timed_de;

wire                       line_buf_ready;
wire                       line_buf_start;
wire [31:0]                line_buf_frame_id;
wire [9:0]                 line_buf_line_id;
wire                       line_buf_wr_en;
wire [6:0]                 line_buf_wr_idx;
wire [AXI_DATA_WIDTH-1:0]  line_buf_wr_data;
wire                       line_buf_done;

wire                       direct_line_valid;
wire [31:0]                direct_frame_id;
wire [9:0]                 direct_line_id;
wire                       direct_line_consume;
wire [9:0]                 direct_pixel_x;
wire [15:0]                direct_pixel_data;

wire                       mac_rx_error;
wire                       mac_rx_data_valid;
wire [7:0]                 mac_rx_data;
wire                       mac_data_valid;
wire [7:0]                 mac_tx_data;
wire                       dbg_udp_active;
wire [3:0]                 dbg_line_bucket;
wire                       reset_out_n;
wire [7:0]                 debug_status;
wire                       active_src_line_valid;

reg                        dbg_frame_write_toggle = 1'b0;
reg                        dbg_frame_read_toggle  = 1'b0;
(* async_reg = "true" *) reg dbg_frame_write_toggle_sys1 = 1'b0;
(* async_reg = "true" *) reg dbg_frame_write_toggle_sys2 = 1'b0;
reg                        dbg_frame_write_toggle_sys2_d = 1'b0;
(* async_reg = "true" *) reg dbg_frame_read_toggle_sys1  = 1'b0;
(* async_reg = "true" *) reg dbg_frame_read_toggle_sys2  = 1'b0;
reg                        dbg_frame_read_toggle_sys2_d  = 1'b0;
(* async_reg = "true" *) reg dbg_udp_active_sys1         = 1'b0;
(* async_reg = "true" *) reg dbg_udp_active_sys2         = 1'b0;
(* async_reg = "true" *) reg process_de_sys1             = 1'b0;
(* async_reg = "true" *) reg process_de_sys2             = 1'b0;
(* async_reg = "true" *) reg direct_line_valid_sys1      = 1'b0;
(* async_reg = "true" *) reg direct_line_valid_sys2      = 1'b0;
(* async_reg = "true" *) reg active_src_line_valid_sys1  = 1'b0;
(* async_reg = "true" *) reg active_src_line_valid_sys2  = 1'b0;
reg                        write_base_vs_d               = 1'b0;
reg                        write_frame_gate              = 1'b0;
reg [19:0]                 pixclk_diag_div              = 20'd0;
reg                        pixclk_diag_toggle           = 1'b0;
reg                        vs_in_d                      = 1'b0;
reg                        de_in_d                      = 1'b0;
reg                        raw_process_vs_d             = 1'b0;
reg                        raw_process_de_d             = 1'b0;
reg                        write_src_vs_d_pix           = 1'b0;
reg                        write_src_de_d_pix           = 1'b0;
reg                        diag_vs_toggle               = 1'b0;
reg                        diag_de_toggle               = 1'b0;
reg                        diag_raw_vs_toggle           = 1'b0;
reg                        diag_raw_de_toggle           = 1'b0;
reg                        diag_write_vs_toggle         = 1'b0;
reg                        diag_write_de_toggle         = 1'b0;
reg [11:0]                 de_width_cnt                = 12'd0;
reg                        diag_de_width_ok_toggle     = 1'b0;
reg                        diag_raw_line_full_toggle   = 1'b0;
(* async_reg = "true" *) reg pixclk_diag_toggle_sys1    = 1'b0;
(* async_reg = "true" *) reg pixclk_diag_toggle_sys2    = 1'b0;
reg                        pixclk_diag_toggle_sys2_d    = 1'b0;
(* async_reg = "true" *) reg diag_vs_toggle_sys1        = 1'b0;
(* async_reg = "true" *) reg diag_vs_toggle_sys2        = 1'b0;
reg                        diag_vs_toggle_sys2_d        = 1'b0;
(* async_reg = "true" *) reg diag_de_toggle_sys1        = 1'b0;
(* async_reg = "true" *) reg diag_de_toggle_sys2        = 1'b0;
reg                        diag_de_toggle_sys2_d        = 1'b0;
(* async_reg = "true" *) reg diag_raw_vs_toggle_sys1    = 1'b0;
(* async_reg = "true" *) reg diag_raw_vs_toggle_sys2    = 1'b0;
reg                        diag_raw_vs_toggle_sys2_d    = 1'b0;
(* async_reg = "true" *) reg diag_raw_de_toggle_sys1    = 1'b0;
(* async_reg = "true" *) reg diag_raw_de_toggle_sys2    = 1'b0;
reg                        diag_raw_de_toggle_sys2_d    = 1'b0;
(* async_reg = "true" *) reg diag_write_vs_toggle_sys1  = 1'b0;
(* async_reg = "true" *) reg diag_write_vs_toggle_sys2  = 1'b0;
reg                        diag_write_vs_toggle_sys2_d  = 1'b0;
(* async_reg = "true" *) reg diag_write_de_toggle_sys1  = 1'b0;
(* async_reg = "true" *) reg diag_write_de_toggle_sys2  = 1'b0;
reg                        diag_write_de_toggle_sys2_d  = 1'b0;
(* async_reg = "true" *) reg diag_de_width_ok_toggle_sys1 = 1'b0;
(* async_reg = "true" *) reg diag_de_width_ok_toggle_sys2 = 1'b0;
reg                        diag_de_width_ok_toggle_sys2_d = 1'b0;
(* async_reg = "true" *) reg diag_raw_line_full_toggle_sys1 = 1'b0;
(* async_reg = "true" *) reg diag_raw_line_full_toggle_sys2 = 1'b0;
reg                        diag_raw_line_full_toggle_sys2_d = 1'b0;

assign init_over_rx = rx_init_done;
assign hdmi_int_led = rx_init_done;
assign reset_out_n  = (rstn_1ms == 16'h2710);
assign phy_rstn     = reset_out_n;
assign write_data   = {sc_r[7:3], sc_g[7:2], sc_b[7:3]};
assign test_hdmi_timing_data = (sc_x < 10'd80)  ? 16'hF800 :
                               (sc_x < 10'd160) ? 16'hFD20 :
                               (sc_x < 10'd240) ? 16'hFFE0 :
                               (sc_x < 10'd320) ? 16'h07E0 :
                               (sc_x < 10'd400) ? 16'h07FF :
                               (sc_x < 10'd480) ? 16'h001F :
                               (sc_x < 10'd560) ? 16'hF81F : 16'hFFFF;
assign test_raw_timing_data = (raw_sc_x < 10'd80)  ? 16'hF800 :
                              (raw_sc_x < 10'd160) ? 16'hFD20 :
                              (raw_sc_x < 10'd240) ? 16'hFFE0 :
                              (raw_sc_x < 10'd320) ? 16'h07E0 :
                              (raw_sc_x < 10'd400) ? 16'h07FF :
                              (raw_sc_x < 10'd480) ? 16'h001F :
                              (raw_sc_x < 10'd560) ? 16'hF81F : 16'hFFFF;
assign use_hdmi_timing_gate = (TEST_INPUT_MODE == INPUT_MODE_HDMI) ||
                              (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_HDMI_TIMING) ||
                              (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_RAW_TIMING);
assign write_src_clk  = (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_SYS) ? sys_clk   : pixclk_in;
assign write_base_vs  = (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_SYS) ? test_src_vs   :
                        (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_PIXCLK) ? test_pixclk_vs :
                        (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_RAW_TIMING) ? raw_process_vs :
                        process_vs;
assign write_base_de  = (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_SYS) ? test_src_de   :
                        (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_PIXCLK) ? test_pixclk_de :
                        (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_RAW_TIMING) ? raw_process_de :
                        process_de;
assign write_base_data = (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_SYS) ? test_src_data :
                         (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_PIXCLK) ? test_pixclk_data :
                         (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_RAW_TIMING) ? test_raw_timing_data :
                         (TEST_INPUT_MODE == INPUT_MODE_COLOR_BAR_HDMI_TIMING) ? test_hdmi_timing_data :
                         write_data;
assign write_timed_vs = write_frame_gate & write_base_vs;
assign write_timed_de = write_frame_gate & write_base_de;
assign write_src_vs   = use_hdmi_timing_gate ? write_timed_vs : write_base_vs;
assign write_src_de   = use_hdmi_timing_gate ? write_timed_de : write_base_de;
assign write_src_data = write_base_data;
assign active_src_line_valid = direct_line_valid &&
                               (direct_line_id >= TOP_PAD_LINES) &&
                               (direct_line_id < ACTIVE_END_LINE);

always @(posedge pixclk_in or negedge reset_out_n) begin
    if (!reset_out_n) begin
        write_base_vs_d  <= 1'b0;
        write_frame_gate <= 1'b0;
        pixclk_diag_div  <= 20'd0;
        pixclk_diag_toggle <= 1'b0;
        vs_in_d          <= 1'b0;
        de_in_d          <= 1'b0;
        raw_process_vs_d <= 1'b0;
        raw_process_de_d <= 1'b0;
        write_src_vs_d_pix <= 1'b0;
        write_src_de_d_pix <= 1'b0;
        diag_vs_toggle   <= 1'b0;
        diag_de_toggle   <= 1'b0;
        diag_raw_vs_toggle <= 1'b0;
        diag_raw_de_toggle <= 1'b0;
        diag_write_vs_toggle <= 1'b0;
        diag_write_de_toggle <= 1'b0;
        de_width_cnt <= 12'd0;
        diag_de_width_ok_toggle <= 1'b0;
        diag_raw_line_full_toggle <= 1'b0;
    end else begin
        pixclk_diag_div <= pixclk_diag_div + 1'b1;
        if (pixclk_diag_div == 20'd0)
            pixclk_diag_toggle <= ~pixclk_diag_toggle;

        write_base_vs_d <= write_base_vs;
        if (use_hdmi_timing_gate && write_base_vs && ~write_base_vs_d)
            write_frame_gate <= ~write_frame_gate;

        if (vs_in && ~vs_in_d)
            diag_vs_toggle <= ~diag_vs_toggle;
        if (de_in && ~de_in_d)
            diag_de_toggle <= ~diag_de_toggle;
        if (raw_process_vs && ~raw_process_vs_d)
            diag_raw_vs_toggle <= ~diag_raw_vs_toggle;
        if (raw_process_de && ~raw_process_de_d)
            diag_raw_de_toggle <= ~diag_raw_de_toggle;
        if (write_src_vs && ~write_src_vs_d_pix)
            diag_write_vs_toggle <= ~diag_write_vs_toggle;
        if (write_src_de && ~write_src_de_d_pix)
            diag_write_de_toggle <= ~diag_write_de_toggle;
        if (raw_process_de && (raw_sc_x == IMG_WIDTH - 1))
            diag_raw_line_full_toggle <= ~diag_raw_line_full_toggle;

        if (de_in) begin
            if (de_width_cnt != 12'hfff)
                de_width_cnt <= de_width_cnt + 1'b1;
        end else begin
            if (de_in_d && (de_width_cnt >= 12'd1900) && (de_width_cnt <= 12'd1940))
                diag_de_width_ok_toggle <= ~diag_de_width_ok_toggle;
            de_width_cnt <= 12'd0;
        end

        vs_in_d            <= vs_in;
        de_in_d            <= de_in;
        raw_process_vs_d   <= raw_process_vs;
        raw_process_de_d   <= raw_process_de;
        write_src_vs_d_pix <= write_src_vs;
        write_src_de_d_pix <= write_src_de;
    end
end

always @(posedge sys_clk or negedge rst_in) begin
    if (!rst_in)
        rstn_1ms <= 16'd0;
    else if (rstn_1ms != 16'h2710)
        rstn_1ms <= rstn_1ms + 1'b1;
end

always @(posedge core_clk or negedge ddr_init_done) begin
    if (!ddr_init_done) begin
        heartbeat_cnt   <= 27'd0;
        heart_beat_led  <= 1'b1;
    end else begin
        if (heartbeat_cnt >= HEARTBEAT_1S) begin
            heartbeat_cnt  <= 27'd0;
            heart_beat_led <= ~heart_beat_led;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
        end
    end
end

always @(posedge core_clk or negedge core_clk_rst_n) begin
    if (!core_clk_rst_n) begin
        latest_frame_valid <= 1'b0;
        latest_frame_id    <= 32'd0;
        latest_frame_seq   <= 32'd0;
        latest_frame_slot  <= 1'b0;
        dbg_frame_write_toggle <= 1'b0;
        dbg_frame_read_toggle  <= 1'b0;
    end else if (frame_wirq) begin
        latest_frame_valid <= 1'b1;
        latest_frame_id    <= latest_frame_seq;
        latest_frame_seq   <= latest_frame_seq + 1'b1;
        // Follow the writer-reported slot directly. The opposite-slot scheme
        // can leave the network side stuck on a stale gray frame.
        latest_frame_slot  <= frame_wcnt[0];
        dbg_frame_write_toggle <= ~dbg_frame_write_toggle;
    end else if (line_buf_done && (line_buf_line_id == SRC_IMG_HEIGHT - 1)) begin
        dbg_frame_read_toggle <= ~dbg_frame_read_toggle;
    end
end

assign debug_status[0] = dbg_frame_write_toggle;
assign debug_status[1] = dbg_frame_read_toggle;
assign debug_status[2] = dbg_udp_active;
assign debug_status[3] = direct_line_valid;
assign debug_status[7:4] = dbg_line_bucket;
assign led = led_reg;

always @(posedge sys_clk or negedge rst_in) begin
    if (!rst_in) begin
        dbg_frame_write_toggle_sys1 <= 1'b0;
        dbg_frame_write_toggle_sys2 <= 1'b0;
        dbg_frame_write_toggle_sys2_d <= 1'b0;
        dbg_frame_read_toggle_sys1  <= 1'b0;
        dbg_frame_read_toggle_sys2  <= 1'b0;
        dbg_frame_read_toggle_sys2_d <= 1'b0;
        dbg_udp_active_sys1         <= 1'b0;
        dbg_udp_active_sys2         <= 1'b0;
        process_de_sys1             <= 1'b0;
        process_de_sys2             <= 1'b0;
        direct_line_valid_sys1      <= 1'b0;
        direct_line_valid_sys2      <= 1'b0;
        active_src_line_valid_sys1  <= 1'b0;
        active_src_line_valid_sys2  <= 1'b0;
        pixclk_diag_toggle_sys1     <= 1'b0;
        pixclk_diag_toggle_sys2     <= 1'b0;
        pixclk_diag_toggle_sys2_d   <= 1'b0;
        diag_vs_toggle_sys1         <= 1'b0;
        diag_vs_toggle_sys2         <= 1'b0;
        diag_vs_toggle_sys2_d       <= 1'b0;
        diag_de_toggle_sys1         <= 1'b0;
        diag_de_toggle_sys2         <= 1'b0;
        diag_de_toggle_sys2_d       <= 1'b0;
        diag_raw_vs_toggle_sys1     <= 1'b0;
        diag_raw_vs_toggle_sys2     <= 1'b0;
        diag_raw_vs_toggle_sys2_d   <= 1'b0;
        diag_raw_de_toggle_sys1     <= 1'b0;
        diag_raw_de_toggle_sys2     <= 1'b0;
        diag_raw_de_toggle_sys2_d   <= 1'b0;
        diag_write_vs_toggle_sys1   <= 1'b0;
        diag_write_vs_toggle_sys2   <= 1'b0;
        diag_write_vs_toggle_sys2_d <= 1'b0;
        diag_write_de_toggle_sys1   <= 1'b0;
        diag_write_de_toggle_sys2   <= 1'b0;
        diag_write_de_toggle_sys2_d <= 1'b0;
        diag_de_width_ok_toggle_sys1 <= 1'b0;
        diag_de_width_ok_toggle_sys2 <= 1'b0;
        diag_de_width_ok_toggle_sys2_d <= 1'b0;
        diag_raw_line_full_toggle_sys1 <= 1'b0;
        diag_raw_line_full_toggle_sys2 <= 1'b0;
        diag_raw_line_full_toggle_sys2_d <= 1'b0;
        led0_cnt <= 23'd0;
        led1_cnt <= 23'd0;
        led2_cnt <= 23'd0;
        led3_cnt <= 23'd0;
        led4_cnt <= 23'd0;
        led5_cnt <= 23'd0;
        led6_cnt <= 23'd0;
        led7_cnt <= 23'd0;
        led_reg  <= 8'd0;
    end else begin
        dbg_frame_write_toggle_sys1 <= dbg_frame_write_toggle;
        dbg_frame_write_toggle_sys2 <= dbg_frame_write_toggle_sys1;
        dbg_frame_write_toggle_sys2_d <= dbg_frame_write_toggle_sys2;
        dbg_frame_read_toggle_sys1  <= dbg_frame_read_toggle;
        dbg_frame_read_toggle_sys2  <= dbg_frame_read_toggle_sys1;
        dbg_frame_read_toggle_sys2_d <= dbg_frame_read_toggle_sys2;
        dbg_udp_active_sys1         <= dbg_udp_active;
        dbg_udp_active_sys2         <= dbg_udp_active_sys1;
        process_de_sys1             <= write_src_de;
        process_de_sys2             <= process_de_sys1;
        direct_line_valid_sys1      <= direct_line_valid;
        direct_line_valid_sys2      <= direct_line_valid_sys1;
        active_src_line_valid_sys1  <= active_src_line_valid;
        active_src_line_valid_sys2  <= active_src_line_valid_sys1;
        pixclk_diag_toggle_sys1     <= pixclk_diag_toggle;
        pixclk_diag_toggle_sys2     <= pixclk_diag_toggle_sys1;
        pixclk_diag_toggle_sys2_d   <= pixclk_diag_toggle_sys2;
        diag_vs_toggle_sys1         <= diag_vs_toggle;
        diag_vs_toggle_sys2         <= diag_vs_toggle_sys1;
        diag_vs_toggle_sys2_d       <= diag_vs_toggle_sys2;
        diag_de_toggle_sys1         <= diag_de_toggle;
        diag_de_toggle_sys2         <= diag_de_toggle_sys1;
        diag_de_toggle_sys2_d       <= diag_de_toggle_sys2;
        diag_raw_vs_toggle_sys1     <= diag_raw_vs_toggle;
        diag_raw_vs_toggle_sys2     <= diag_raw_vs_toggle_sys1;
        diag_raw_vs_toggle_sys2_d   <= diag_raw_vs_toggle_sys2;
        diag_raw_de_toggle_sys1     <= diag_raw_de_toggle;
        diag_raw_de_toggle_sys2     <= diag_raw_de_toggle_sys1;
        diag_raw_de_toggle_sys2_d   <= diag_raw_de_toggle_sys2;
        diag_write_vs_toggle_sys1   <= diag_write_vs_toggle;
        diag_write_vs_toggle_sys2   <= diag_write_vs_toggle_sys1;
        diag_write_vs_toggle_sys2_d <= diag_write_vs_toggle_sys2;
        diag_write_de_toggle_sys1   <= diag_write_de_toggle;
        diag_write_de_toggle_sys2   <= diag_write_de_toggle_sys1;
        diag_write_de_toggle_sys2_d <= diag_write_de_toggle_sys2;
        diag_de_width_ok_toggle_sys1 <= diag_de_width_ok_toggle;
        diag_de_width_ok_toggle_sys2 <= diag_de_width_ok_toggle_sys1;
        diag_de_width_ok_toggle_sys2_d <= diag_de_width_ok_toggle_sys2;
        diag_raw_line_full_toggle_sys1 <= diag_raw_line_full_toggle;
        diag_raw_line_full_toggle_sys2 <= diag_raw_line_full_toggle_sys1;
        diag_raw_line_full_toggle_sys2_d <= diag_raw_line_full_toggle_sys2;

        if (pixclk_diag_toggle_sys2 != pixclk_diag_toggle_sys2_d)
            led0_cnt <= LED_HOLD_CNT;
        else if (led0_cnt != 23'd0)
            led0_cnt <= led0_cnt - 1'b1;

        if (diag_vs_toggle_sys2 != diag_vs_toggle_sys2_d)
            led1_cnt <= LED_HOLD_CNT;
        else if (led1_cnt != 23'd0)
            led1_cnt <= led1_cnt - 1'b1;

        if (diag_de_toggle_sys2 != diag_de_toggle_sys2_d)
            led2_cnt <= LED_HOLD_CNT;
        else if (led2_cnt != 23'd0)
            led2_cnt <= led2_cnt - 1'b1;

        if (diag_de_width_ok_toggle_sys2 != diag_de_width_ok_toggle_sys2_d)
            led3_cnt <= LED_HOLD_CNT;
        else if (led3_cnt != 23'd0)
            led3_cnt <= led3_cnt - 1'b1;

        if (diag_raw_vs_toggle_sys2 != diag_raw_vs_toggle_sys2_d)
            led4_cnt <= LED_HOLD_CNT;
        else if (led4_cnt != 23'd0)
            led4_cnt <= led4_cnt - 1'b1;

        if (diag_raw_de_toggle_sys2 != diag_raw_de_toggle_sys2_d)
            led5_cnt <= LED_HOLD_CNT;
        else if (led5_cnt != 23'd0)
            led5_cnt <= led5_cnt - 1'b1;

        if (diag_raw_line_full_toggle_sys2 != diag_raw_line_full_toggle_sys2_d)
            led6_cnt <= LED_HOLD_CNT;
        else if (led6_cnt != 23'd0)
            led6_cnt <= led6_cnt - 1'b1;

        if (dbg_frame_write_toggle_sys2 != dbg_frame_write_toggle_sys2_d)
            led7_cnt <= LED_HOLD_CNT;
        else if (led7_cnt != 23'd0)
            led7_cnt <= led7_cnt - 1'b1;

        led_reg[0] <= (led0_cnt != 23'd0);
        led_reg[1] <= (led1_cnt != 23'd0);
        led_reg[2] <= (led2_cnt != 23'd0);
        led_reg[3] <= (led3_cnt != 23'd0);
        led_reg[4] <= (led4_cnt != 23'd0);
        led_reg[5] <= (led5_cnt != 23'd0);
        led_reg[6] <= (led6_cnt != 23'd0);
        led_reg[7] <= (led7_cnt != 23'd0);
    end
end

always @(posedge pixclk_in or negedge reset_out_n) begin
    if (!reset_out_n) begin
        csc_de_r <= 1'b0;
        csc_vs_r <= 1'b0;
        csc_y_r  <= 8'd0;
        csc_u_r  <= 8'd0;
        csc_v_r  <= 8'd0;
    end else begin
        csc_de_r <= csc_de;
        csc_vs_r <= csc_vs;
        csc_y_r  <= csc_y;
        csc_u_r  <= csc_u;
        csc_v_r  <= csc_v;
    end
end

ms72xx_ctl u_ms72xx_ctl(
    .clk         ( cfg_clk      ),
    .rst_n       ( reset_out_n  ),
    .init_over   ( rx_init_done ),
    .iic_rx_scl  ( hd_scl       ),
    .iic_rx_sda  ( hd_sda       ),
    .iic_scl     (              ),
    .iic_sda     (              )
);

gamma_lookuptable u_gamma_lookuptable_r(
    .video_clk  ( pixclk_in ),
    .video_data ( r_in      ),
    .video_de   ( de_in     ),
    .gamma_de   ( gamma_de     ),
    .gamma_data ( gamma_data_r )
);

gamma_lookuptable u_gamma_lookuptable_g(
    .video_clk  ( pixclk_in ),
    .video_data ( g_in      ),
    .video_de   ( de_in     ),
    .gamma_de   (           ),
    .gamma_data ( gamma_data_g )
);

gamma_lookuptable u_gamma_lookuptable_b(
    .video_clk  ( pixclk_in ),
    .video_data ( b_in      ),
    .video_de   ( de_in     ),
    .gamma_de   (           ),
    .gamma_data ( gamma_data_b )
);

rgb_gauss u_rgb_gauss(
    .clk       ( pixclk_in ),
    .rst_n     ( reset_out_n  ),
    .pre_vsync ( vs_in     ),
    .pre_hsync ( gamma_de  ),
    .pre_href  ( gamma_de  ),
    .pre_r     ( gamma_data_r ),
    .pre_g     ( gamma_data_g ),
    .pre_b     ( gamma_data_b ),
    .post_vsync( gauss_vs  ),
    .post_hsync(           ),
    .post_href ( gauss_de  ),
    .post_r    ( gauss_r   ),
    .post_g    ( gauss_g   ),
    .post_b    ( gauss_b   )
);

isp_csc u_isp_csc(
    .pclk      ( pixclk_in ),
    .rst_n     ( reset_out_n  ),
    .in_href   ( gauss_de  ),
    .in_vsync  ( gauss_vs  ),
    .in_r      ( gauss_r   ),
    .in_g      ( gauss_g   ),
    .in_b      ( gauss_b   ),
    .out_href  ( csc_de    ),
    .out_vsync ( csc_vs    ),
    .out_y     ( csc_y     ),
    .out_u     ( csc_u     ),
    .out_v     ( csc_v     )
);

isp_ee u_isp_ee(
    .pclk      ( pixclk_in ),
    .rst_n     ( reset_out_n  ),
    .in_href   ( csc_de_r  ),
    .in_vsync  ( csc_vs_r  ),
    .in_y      ( csc_y_r   ),
    .in_u      ( csc_u_r   ),
    .in_v      ( csc_v_r   ),
    .out_href  ( ee_de     ),
    .out_vsync ( ee_vs     ),
    .out_y     ( ee_y      ),
    .out_u     ( ee_u      ),
    .out_v     ( ee_v      )
);

isp_occ u_isp_occ(
    .pclk      ( pixclk_in ),
    .rst_n     ( reset_out_n  ),
    .in_href   ( ee_de     ),
    .in_vsync  ( ee_vs     ),
    .in_y      ( ee_y      ),
    .in_u      ( ee_u      ),
    .in_v      ( ee_v      ),
    .out_href  ( occ_de    ),
    .out_vsync ( occ_vs    ),
    .out_r     ( occ_r     ),
    .out_g     ( occ_g     ),
    .out_b     ( occ_b     )
);

scale3x_downsampler u_scale3x_downsampler (
    .rst_n          ( reset_out_n   ),
    .pix_clk_in     ( pixclk_in  ),
    .in_r           ( occ_r      ),
    .in_g           ( occ_g      ),
    .in_b           ( occ_b      ),
    .in_vsync_valid ( occ_vs     ),
    .in_de          ( occ_de     ),
    .sc_r           ( sc_r       ),
    .sc_g           ( sc_g       ),
    .sc_b           ( sc_b       ),
    .sc_de          ( process_de ),
    .sc_vsync_pulse ( process_vs ),
    .sc_x           ( sc_x       ),
    .sc_y           ( sc_y       )
);

scale3x_downsampler u_scale3x_downsampler_raw (
    .rst_n          ( reset_out_n    ),
    .pix_clk_in     ( pixclk_in      ),
    .in_r           ( r_in           ),
    .in_g           ( g_in           ),
    .in_b           ( b_in           ),
    .in_vsync_valid ( vs_in          ),
    .in_de          ( de_in          ),
    .sc_r           ( raw_sc_r       ),
    .sc_g           ( raw_sc_g       ),
    .sc_b           ( raw_sc_b       ),
    .sc_de          ( raw_process_de ),
    .sc_vsync_pulse ( raw_process_vs ),
    .sc_x           ( raw_sc_x       ),
    .sc_y           ( raw_sc_y       )
);

color_bar_640x360_rgb565 u_color_bar_640x360_rgb565 (
    .clk        ( sys_clk       ),
    .rst_n      ( reset_out_n   ),
    .frame_vs   ( test_src_vs   ),
    .frame_de   ( test_src_de   ),
    .frame_data ( test_src_data )
);

color_bar_640x360_rgb565 u_color_bar_640x360_rgb565_pixclk (
    .clk        ( pixclk_in        ),
    .rst_n      ( reset_out_n      ),
    .frame_vs   ( test_pixclk_vs   ),
    .frame_de   ( test_pixclk_de   ),
    .frame_data ( test_pixclk_data )
);

GTP_INBUFGDS #(
    .IOSTANDARD("DEFAULT"),
    .TERM_DIFF("ON")
) u_ddr_refclk_in (
    .O  ( clk_125mhz ),
    .I  ( clk_p      ),
    .IB ( clk_n      )
);

play_rst_sync u_core_clk_rst_sync (
    .clk        ( core_clk      ),
    .rst_n      ( reset_out_n   ),
    .sig_async  ( 1'b1          ),
    .sig_synced ( core_clk_rst_n )
);

ddr_frame_writer_only #(
    .MEM_ROW_WIDTH    ( MEM_ROW_ADDR_WIDTH ),
    .MEM_COLUMN_WIDTH ( MEM_COL_ADDR_WIDTH ),
    .MEM_BANK_WIDTH   ( MEM_BADDR_WIDTH    ),
    .CTRL_ADDR_WIDTH  ( CTRL_ADDR_WIDTH    ),
    .MEM_DQ_WIDTH     ( MEM_DQ_WIDTH       ),
    .H_NUM            ( IMG_WIDTH          ),
    .V_NUM            ( SRC_IMG_HEIGHT     ),
    .PIX_WIDTH        ( 16                 )
) u_ddr_frame_writer_only (
    .vin_clk       ( write_src_clk  ),
    .wr_fsync      ( ~write_src_vs  ),
    .wr_en         ( write_src_de   ),
    .wr_data       ( write_src_data ),
    .ddr_clk       ( core_clk      ),
    .ddr_rstn      ( ddr_init_done ),
    .frame_wcnt    ( frame_wcnt    ),
    .frame_wirq    ( frame_wirq    ),
    .axi_awaddr    ( axi_awaddr    ),
    .axi_awid      ( axi_awid      ),
    .axi_awlen     ( axi_awlen     ),
    .axi_awsize    ( axi_awsize    ),
    .axi_awburst   ( axi_awburst   ),
    .axi_awready   ( axi_awready   ),
    .axi_awvalid   ( axi_awvalid   ),
    .axi_wdata     ( axi_wdata     ),
    .axi_wstrb     ( axi_wstrb     ),
    .axi_wlast     ( axi_wlast     ),
    .axi_wvalid    ( axi_wvalid    ),
    .axi_wready    ( axi_wready    )
);

ddr_play_reader #(
    .VIDEO_BASE_ADDR  ( 28'd0               ),
    .IMG_WIDTH        ( IMG_WIDTH           ),
    .IMG_HEIGHT       ( SRC_IMG_HEIGHT      ),
    .TOTAL_FRAMES     ( TOTAL_FRAMES        ),
    .AXI_DATA_WIDTH   ( AXI_DATA_WIDTH      ),
    .FRAME_ADDR_STEP  ( FRAME_SLOT_ADDR     ),
    .LINE_ADDR_STEP   ( LINE_ADDR_STEP      ),
    .BEATS_PER_BURST  ( DDR_BEATS_PER_BURST ),
    .BURST_ADDR_STEP  ( BURST_ADDR_STEP     )
 ) u_ddr_play_reader (
    .core_clk         ( core_clk           ),
    .core_rstn        ( core_clk_rst_n     ),
    .ddr_init_done    ( ddr_init_done      ),
    .pll_lock         ( pll_lock           ),
    .play_enable      ( 1'b1               ),
    .latest_frame_valid ( latest_frame_valid ),
    .latest_frame_id    ( latest_frame_id    ),
    .latest_frame_slot  ( latest_frame_slot  ),
    .axi_araddr       ( axi_araddr         ),
    .axi_aruser_ap    ( axi_aruser_ap      ),
    .axi_aruser_id    ( axi_aruser_id      ),
    .axi_arlen        ( axi_arlen          ),
    .axi_arready      ( axi_arready        ),
    .axi_arvalid      ( axi_arvalid        ),
    .axi_rdata        ( axi_rdata          ),
    .axi_rid          ( axi_rid            ),
    .axi_rlast        ( axi_rlast          ),
    .axi_rvalid       ( axi_rvalid         ),
    .line_buf_ready   ( line_buf_ready     ),
    .line_buf_start   ( line_buf_start     ),
    .line_buf_frame_id( line_buf_frame_id  ),
    .line_buf_line_id ( line_buf_line_id   ),
    .line_buf_wr_en   ( line_buf_wr_en     ),
    .line_buf_wr_idx  ( line_buf_wr_idx    ),
    .line_buf_wr_data ( line_buf_wr_data   ),
    .line_buf_done    ( line_buf_done      ),
    .dbg_frame_id     (                    ),
    .dbg_line_id      (                    ),
    .dbg_state        (                    )
);

ref_clock u_rgmii_ref_clock (
    .clkout0 ( rgmii_clk_90p ),
    .clkin1  ( rgmii_rxc     ),
    .lock    ( rgmii_clk_lock )
);

rgmii_interface u_rgmii_interface (
    .rst               ( ~rgmii_clk_rst_n   ),
    .rgmii_clk         ( rgmii_clk          ),
    .rgmii_clk_90p     ( rgmii_clk_90p      ),
    .mac_tx_data_valid ( mac_data_valid     ),
    .mac_tx_data       ( mac_tx_data        ),
    .mac_rx_error      ( mac_rx_error       ),
    .mac_rx_data_valid ( mac_rx_data_valid  ),
    .mac_rx_data       ( mac_rx_data        ),
    .rgmii_rxc         ( rgmii_clk_90p      ),
    .rgmii_rx_ctl      ( rgmii_rx_ctl       ),
    .rgmii_rxd         ( rgmii_rxd          ),
    .rgmii_txc         ( rgmii_txc          ),
    .rgmii_tx_ctl      ( rgmii_tx_ctl       ),
    .rgmii_txd         ( rgmii_txd          )
);

play_rst_sync u_rgmii_clk_rst_sync (
    .clk        ( rgmii_clk       ),
    .rst_n      ( reset_out_n & rgmii_clk_lock ),
    .sig_async  ( 1'b1            ),
    .sig_synced ( rgmii_clk_rst_n )
);

ddr_play_line_bridge #(
    .IMG_WIDTH        ( IMG_WIDTH                ),
    .SRC_HEIGHT       ( SRC_IMG_HEIGHT           ),
    .IMG_HEIGHT       ( IMG_HEIGHT               ),
    .FRAME_PERIOD_CNT ( OUTPUT_FRAME_PERIOD_CNT  ),
    .BEAT_DATA_WIDTH  ( AXI_DATA_WIDTH           )
) u_ddr_play_line_bridge (
    .wr_clk           ( core_clk            ),
    .wr_rstn          ( core_clk_rst_n      ),
    .line_buf_start   ( line_buf_start      ),
    .line_buf_frame_id( line_buf_frame_id   ),
    .line_buf_line_id ( line_buf_line_id    ),
    .line_buf_wr_en   ( line_buf_wr_en      ),
    .line_buf_wr_idx  ( line_buf_wr_idx     ),
    .line_buf_wr_data ( line_buf_wr_data    ),
    .line_buf_done    ( line_buf_done       ),
    .line_buf_ready   ( line_buf_ready      ),
    .rd_clk           ( rgmii_clk           ),
    .rd_rstn          ( rgmii_clk_rst_n     ),
    .rd_line_consume  ( direct_line_consume ),
    .pixel_x          ( direct_pixel_x      ),
    .line_valid       ( direct_line_valid   ),
    .frame_id         ( direct_frame_id     ),
    .line_id          ( direct_line_id      ),
    .pixel_data       ( direct_pixel_data   )
);

eth_udp_test #(
    .LOCAL_MAC           ( LOCAL_MAC                 ),
    .LOCAL_IP            ( LOCAL_IP                  ),
    .LOCL_PORT           ( LOCL_PORT                 ),
    .DEST_MAC            ( DEST_MAC                  ),
    .DEST_IP             ( DEST_IP                   ),
    .DEST_PORT           ( DEST_PORT                 ),
    .FIXED_DEST_MAC_EN   ( FIXED_DEST_MAC_EN         ),
    .USE_DIRECT_LINE_SRC ( 1'b1                      ),
    .IMG_WIDTH           ( IMG_WIDTH                 ),
    .IMG_HEIGHT          ( IMG_HEIGHT                ),
    .FRAME_PERIOD_CNT    ( OUTPUT_FRAME_PERIOD_CNT   )
) u_eth_udp_test (
    .rgmii_clk           ( rgmii_clk           ),
    .rstn                ( rgmii_clk_rst_n     ),
    .gmii_rx_dv          ( mac_rx_data_valid   ),
    .gmii_rxd            ( mac_rx_data         ),
    .vid_clk             ( 1'b0                ),
    .vid_rstn            ( 1'b0                ),
    .vid_vs              ( 1'b0                ),
    .vid_hs              ( 1'b0                ),
    .vid_de              ( 1'b0                ),
    .vid_rgb565          ( 16'd0               ),
    .direct_line_valid   ( direct_line_valid   ),
    .direct_frame_id     ( direct_frame_id     ),
    .direct_line_id      ( direct_line_id      ),
    .direct_line_consume ( direct_line_consume ),
    .direct_pixel_x      ( direct_pixel_x      ),
    .direct_pixel_data   ( direct_pixel_data   ),
    .gmii_tx_en          ( mac_data_valid      ),
    .gmii_txd            ( mac_tx_data         ),
    .dbg_udp_active      ( dbg_udp_active      ),
    .dbg_line_bucket     ( dbg_line_bucket     ),
    .udp_rec_data_valid  (                     ),
    .udp_rec_rdata       (                     ),
    .udp_rec_data_length (                     )
);

ddr3_test u_ddr3_test (
    .ref_clk         ( clk_125mhz    ),
    .resetn          ( reset_out_n   ),
    .ddr_init_done   ( ddr_init_done ),
    .pll_lock        ( pll_lock      ),
    .core_clk        ( core_clk      ),
    .phy_pll_lock    (               ),
    .gpll_lock       (               ),
    .rst_gpll_lock   (               ),
    .ddrphy_cpd_lock (               ),
    .axi_awaddr      ( axi_awaddr    ),
    .axi_awuser_ap   ( 1'b0          ),
    .axi_awuser_id   ( axi_awid      ),
    .axi_awlen       ( axi_awlen     ),
    .axi_awready     ( axi_awready   ),
    .axi_awvalid     ( axi_awvalid   ),
    .axi_wdata       ( axi_wdata     ),
    .axi_wstrb       ( axi_wstrb     ),
    .axi_wready      ( axi_wready    ),
    .axi_wusero_id   (               ),
    .axi_wusero_last ( axi_wlast     ),
    .axi_araddr      ( axi_araddr    ),
    .axi_aruser_ap   ( axi_aruser_ap ),
    .axi_aruser_id   ( axi_aruser_id ),
    .axi_arlen       ( axi_arlen     ),
    .axi_arready     ( axi_arready   ),
    .axi_arvalid     ( axi_arvalid   ),
    .axi_rdata       ( axi_rdata     ),
    .axi_rid         ( axi_rid       ),
    .axi_rlast       ( axi_rlast     ),
    .axi_rvalid      ( axi_rvalid    ),
    .apb_clk         ( 1'b0          ),
    .apb_rst_n       ( 1'b1          ),
    .apb_sel         ( 1'b0          ),
    .apb_enable      ( 1'b0          ),
    .apb_addr        ( 8'd0          ),
    .apb_write       ( 1'b0          ),
    .apb_ready       (               ),
    .apb_wdata       ( 16'd0         ),
    .apb_rdata       (               ),
    .mem_rst_n       ( mem_rst_n     ),
    .mem_ck          ( mem_ck        ),
    .mem_ck_n        ( mem_ck_n      ),
    .mem_cke         ( mem_cke       ),
    .mem_cs_n        ( mem_cs_n      ),
    .mem_ras_n       ( mem_ras_n     ),
    .mem_cas_n       ( mem_cas_n     ),
    .mem_we_n        ( mem_we_n      ),
    .mem_odt         ( mem_odt       ),
    .mem_a           ( mem_a         ),
    .mem_ba          ( mem_ba        ),
    .mem_dqs         ( mem_dqs       ),
    .mem_dqs_n       ( mem_dqs_n     ),
    .mem_dq          ( mem_dq        ),
    .mem_dm          ( mem_dm        ),
    .dbg_gate_start  ( 1'b0          ),
    .dbg_cpd_start   ( 1'b0          ),
    .dbg_ddrphy_rst_n( 1'b1          ),
    .dbg_gpll_scan_rst(1'b0          ),
    .samp_position_dyn_adj ( 1'b0    ),
    .init_samp_position_even(32'd0   ),
    .init_samp_position_odd (32'd0   ),
    .wrcal_position_dyn_adj (1'b0    ),
    .init_wrcal_position    (32'd0   ),
    .force_read_clk_ctrl    (1'b0    ),
    .init_slip_step         (16'd0   ),
    .init_read_clk_ctrl     (12'd0   ),
    .debug_calib_ctrl       (        ),
    .dbg_slice_status       (        ),
    .dbg_slice_state        (        ),
    .debug_data             (        ),
    .dbg_dll_upd_state      (        ),
    .debug_gpll_dps_phase   (        ),
    .dbg_rst_dps_state      (        ),
    .dbg_tran_err_rst_cnt   (        ),
    .dbg_ddrphy_init_fail   (        ),
    .debug_cpd_offset_adj   (1'b0    ),
    .debug_cpd_offset_dir   (1'b0    ),
    .debug_cpd_offset       (10'd0   ),
    .debug_dps_cnt_dir0     (        ),
    .debug_dps_cnt_dir1     (        ),
    .ck_dly_en              (1'b0    ),
    .init_ck_dly_step       (8'h0    ),
    .ck_dly_set_bin         (        ),
    .align_error            (        ),
    .debug_rst_state        (        ),
    .debug_cpd_state        (        )
);

endmodule

module color_bar_640x360_rgb565 #(
    parameter integer H_ACTIVE = 640,
    parameter integer V_ACTIVE = 360,
    parameter integer H_TOTAL  = 800,
    parameter integer V_TOTAL  = 525
)(
    input             clk,
    input             rst_n,
    output reg        frame_vs,
    output reg        frame_de,
    output reg [15:0] frame_data
);

    reg [10:0] h_cnt;
    reg [9:0]  v_cnt;

    wire active_area;
    wire [2:0] bar_sel;

    assign active_area = (h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE);
    assign bar_sel = (h_cnt < 11'd80)  ? 3'd0 :
                     (h_cnt < 11'd160) ? 3'd1 :
                     (h_cnt < 11'd240) ? 3'd2 :
                     (h_cnt < 11'd320) ? 3'd3 :
                     (h_cnt < 11'd400) ? 3'd4 :
                     (h_cnt < 11'd480) ? 3'd5 :
                     (h_cnt < 11'd560) ? 3'd6 : 3'd7;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt      <= 11'd0;
            v_cnt      <= 10'd0;
            frame_vs   <= 1'b0;
            frame_de   <= 1'b0;
            frame_data <= 16'h0000;
        end else begin
            frame_vs <= (h_cnt == 11'd0) && (v_cnt == 10'd0);
            frame_de <= active_area;

            if (active_area) begin
                case (bar_sel)
                    3'd0: frame_data <= 16'hF800;
                    3'd1: frame_data <= 16'hFD20;
                    3'd2: frame_data <= 16'hFFE0;
                    3'd3: frame_data <= 16'h07E0;
                    3'd4: frame_data <= 16'h07FF;
                    3'd5: frame_data <= 16'h001F;
                    3'd6: frame_data <= 16'hF81F;
                    default: frame_data <= 16'hFFFF;
                endcase
            end else begin
                frame_data <= 16'h0000;
            end

            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 11'd0;
                if (v_cnt == V_TOTAL - 1)
                    v_cnt <= 10'd0;
                else
                    v_cnt <= v_cnt + 10'd1;
            end else begin
                h_cnt <= h_cnt + 11'd1;
            end
        end
    end

endmodule
