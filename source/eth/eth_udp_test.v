`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2022/03/16 23:40:05
// Design Name:
// Module Name: eth_udp_test
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module eth_udp_test#(
    parameter       LOCAL_MAC = 48'h11_11_11_11_11_11,
    parameter       LOCAL_IP  = 32'hC0_A8_01_6E,//192.168.1.110
    parameter       LOCL_PORT = 16'h8080,

    parameter       DEST_MAC  = 48'h9A_CB_4C_37_BF_00,
    parameter       DEST_IP   = 32'hC0_A8_01_69,//192.168.1.105
    parameter       DEST_PORT = 16'h8080,
    parameter       FIXED_DEST_MAC_EN = 1'b1,
    parameter       USE_DIRECT_LINE_SRC = 1'b0,
    parameter integer IMG_WIDTH         = 640,
    parameter integer IMG_HEIGHT        = 640,
    parameter integer FRAME_PERIOD_CNT  = 2083333,
    parameter integer PACKET_HEADER_BYTES = 6
)(
    input                rgmii_clk,
    input                rstn,
    input                gmii_rx_dv,
    input  [7:0]         gmii_rxd,
    input                vid_clk,
    input                vid_rstn,
    input                vid_vs,
    input                vid_hs,
    input                vid_de,
    input  [15:0]        vid_rgb565,
    input                direct_line_valid,
    input  [31:0]        direct_frame_id,
    input  [9:0]         direct_line_id,
    output               direct_line_consume,
    output [9:0]         direct_pixel_x,
    input  [15:0]        direct_pixel_data,
    output reg           gmii_tx_en,
    output reg [7:0]     gmii_txd,
    output               dbg_udp_active,
    output [3:0]         dbg_line_bucket,

    output               udp_rec_data_valid,
    output [7:0]         udp_rec_rdata,
    output [15:0]        udp_rec_data_length
);

    localparam integer UDP_PACKET_BYTES    = PACKET_HEADER_BYTES + IMG_WIDTH * 2;
    localparam integer LINE_STEP_CNT       = FRAME_PERIOD_CNT / IMG_HEIGHT;
    localparam integer LINE_STEP_REM       = FRAME_PERIOD_CNT % IMG_HEIGHT;

    reg   [7:0]          ram_wr_data;
    reg                  ram_wr_en;
    wire                 udp_ram_data_req;
    reg [15:0]           udp_send_data_length;

    wire                 udp_tx_req;
    wire                 arp_request_req;
    wire                 mac_send_end;
    reg                  write_end;

    reg  [31:0]          wait_cnt;
    wire                 mac_not_exist;
    wire                 arp_found;

    reg [31:0]           frame_cnt;
    reg [9:0]            line_cnt;
    reg [10:0]           packet_byte_cnt;
    reg [31:0]           local_frame_seq;
    reg [9:0]            last_line_id;
    reg                  frame_seq_init;
    reg [31:0]           packet_frame_id;
    reg [9:0]            packet_line_id;

    localparam IDLE           = 10'b00_0000_0001;
    localparam ARP_REQ        = 10'b00_0000_0010;
    localparam ARP_SEND       = 10'b00_0000_0100;
    localparam ARP_WAIT       = 10'b00_0000_1000;
    localparam CHECK_ARP      = 10'b00_0001_0000;
    localparam GEN_REQ        = 10'b00_0010_0000;
    localparam WRITE_RAM      = 10'b00_0100_0000;
    localparam SEND           = 10'b00_1000_0000;
    localparam WAIT_LINE      = 10'b01_0000_0000;
    localparam STATE_UNUSED   = 10'b10_0000_0000;
    localparam ONE_SECOND_CNT = 32'd125_000_000;

    reg [9:0] state;
    reg [9:0] state_n;

    reg        gmii_rx_dv_1d;
    reg [7:0]  gmii_rxd_1d;
    wire       gmii_tx_en_tmp;
    wire [7:0] gmii_txd_tmp;

    wire [10:0] payload_byte_idx;
    wire [9:0]  pixel_x;
    wire [15:0] pixel_data;
    wire        src_line_valid;
    wire [31:0] src_frame_id;
    wire [9:0]  src_line_id;
    wire        active_line_valid;
    wire [31:0] active_frame_id;
    wire [9:0]  active_line_id;
    wire [15:0] active_pixel_data;
    wire [31:0] tx_frame_id;
    wire [9:0]  tx_line_id;
    reg         src_line_consume;

    assign payload_byte_idx       = packet_byte_cnt - PACKET_HEADER_BYTES;
    assign pixel_x                = payload_byte_idx[10:1];
    assign active_line_valid      = USE_DIRECT_LINE_SRC ? direct_line_valid   : src_line_valid;
    assign active_frame_id        = USE_DIRECT_LINE_SRC ? direct_frame_id     : src_frame_id;
    assign active_line_id         = USE_DIRECT_LINE_SRC ? direct_line_id      : src_line_id;
    assign active_pixel_data      = USE_DIRECT_LINE_SRC ? direct_pixel_data   : pixel_data;
    assign direct_line_consume    = USE_DIRECT_LINE_SRC ? src_line_consume    : 1'b0;
    assign direct_pixel_x         = USE_DIRECT_LINE_SRC ? pixel_x             : 10'd0;
    assign dbg_udp_active         = (state == WRITE_RAM) || (state == SEND) || gmii_tx_en_tmp;
    assign dbg_line_bucket        = active_line_id[8:5];
    assign tx_frame_id            = local_frame_seq;
    assign tx_line_id             = active_line_id;

    video_line_bridge #(
        .IMG_WIDTH ( IMG_WIDTH  ),
        .IMG_HEIGHT( IMG_HEIGHT )
    ) u_video_line_bridge (
        .vid_clk   ( vid_clk    ),
        .vid_rstn  ( vid_rstn   ),
        .vid_vs    ( vid_vs     ),
        .vid_hs    ( vid_hs     ),
        .vid_de    ( vid_de     ),
        .vid_rgb565( vid_rgb565 ),
        .rd_clk    ( rgmii_clk  ),
        .rd_rstn   ( rstn       ),
        .rd_line_consume( src_line_consume ),
        .pixel_x   ( pixel_x    ),
        .line_valid( src_line_valid ),
        .frame_id  ( src_frame_id ),
        .line_id   ( src_line_id  ),
        .pixel_data( pixel_data )
    );

    always @(posedge rgmii_clk)
    begin
        if (~rstn)
            state <= IDLE;
        else
            state <= state_n;
    end

    always @(*)
    begin
        case(state)
            IDLE:
            begin
                if (wait_cnt == ONE_SECOND_CNT)
                    state_n = FIXED_DEST_MAC_EN ? CHECK_ARP : ARP_REQ;
                else
                    state_n = IDLE;
            end
            ARP_REQ:
                state_n = ARP_SEND;
            ARP_SEND:
            begin
                if (mac_send_end)
                    state_n = ARP_WAIT;
                else
                    state_n = ARP_SEND;
            end
            ARP_WAIT:
            begin
                if (arp_found)
                    state_n = CHECK_ARP;
                else if (wait_cnt == ONE_SECOND_CNT)
                    state_n = ARP_REQ;
                else
                    state_n = ARP_WAIT;
            end
            CHECK_ARP:
            begin
                if (FIXED_DEST_MAC_EN)
                begin
                    if (active_line_valid)
                        state_n = GEN_REQ;
                    else
                        state_n = WAIT_LINE;
                end
                else if (mac_not_exist)
                    state_n = ARP_REQ;
                else if (active_line_valid)
                    state_n = GEN_REQ;
                else
                    state_n = WAIT_LINE;
            end
            GEN_REQ:
            begin
                if (udp_ram_data_req)
                    state_n = WRITE_RAM;
                else
                    state_n = GEN_REQ;
            end
            WRITE_RAM:
            begin
                if (write_end)
                    state_n = SEND;
                else
                    state_n = WRITE_RAM;
            end
            SEND:
            begin
                if (mac_send_end)
                    state_n = CHECK_ARP;
                else
                    state_n = SEND;
            end
            WAIT_LINE:
            begin
                if (active_line_valid)
                    state_n = CHECK_ARP;
                else
                    state_n = WAIT_LINE;
            end
            default:
                state_n = IDLE;
        endcase
    end

    always @(posedge rgmii_clk)
    begin
        if(rstn == 1'b0)
        begin
            gmii_rx_dv_1d <= 1'b0;
            gmii_rxd_1d   <= 8'd0;
        end
        else
        begin
            gmii_rx_dv_1d <= gmii_rx_dv;
            gmii_rxd_1d   <= gmii_rxd;
        end
    end

    always @(posedge rgmii_clk)
    begin
        if(rstn == 1'b0)
        begin
            gmii_tx_en <= 1'b0;
            gmii_txd   <= 8'd0;
        end
        else
        begin
            gmii_tx_en <= gmii_tx_en_tmp;
            gmii_txd   <= gmii_txd_tmp;
        end
    end

    udp_ip_mac_top#(
        .LOCAL_MAC                (LOCAL_MAC               ),
        .LOCAL_IP                 (LOCAL_IP                ),
        .LOCL_PORT                (LOCL_PORT               ),
        .DEST_MAC                 (DEST_MAC                ),
        .DEST_IP                  (DEST_IP                 ),
        .DEST_PORT                (DEST_PORT               ),
        .FIXED_DEST_MAC_EN        (FIXED_DEST_MAC_EN       )
    ) udp_ip_mac_top (
        .rgmii_clk                ( rgmii_clk             ),
        .rstn                     ( rstn                  ),

        .app_data_in_valid        ( ram_wr_en             ),
        .app_data_in              ( ram_wr_data           ),
        .app_data_length          ( udp_send_data_length  ),
        .app_data_request         ( udp_tx_req            ),

        .udp_send_ack             ( udp_ram_data_req      ),

        .arp_req                  ( arp_request_req       ),
        .arp_found                ( arp_found             ),
        .mac_not_exist            ( mac_not_exist         ),
        .mac_send_end             ( mac_send_end          ),

        .udp_rec_rdata            ( udp_rec_rdata         ),
        .udp_rec_data_length      ( udp_rec_data_length   ),
        .udp_rec_data_valid       ( udp_rec_data_valid    ),

        .mac_data_valid           ( gmii_tx_en_tmp        ),
        .mac_tx_data              ( gmii_txd_tmp          ),

        .rx_en                    ( gmii_rx_dv_1d         ),
        .mac_rx_datain            ( gmii_rxd_1d           )
    );

    always @(posedge rgmii_clk)
    begin
        if(rstn == 1'b0)
            udp_send_data_length <= 16'd0;
        else
            udp_send_data_length <= UDP_PACKET_BYTES;
    end

    assign udp_tx_req      = (state == GEN_REQ);
    assign arp_request_req = (~FIXED_DEST_MAC_EN) && (state == ARP_REQ);

    always @(posedge rgmii_clk)
    begin
        if(rstn == 1'b0)
            wait_cnt <= 0;
        else if ((state == IDLE || state == ARP_WAIT) && state != state_n)
            wait_cnt <= 0;
        else if (state == IDLE || state == ARP_WAIT)
            wait_cnt <= wait_cnt + 1'b1;
        else
            wait_cnt <= 0;
    end

    always @(posedge rgmii_clk)
    begin
        if(rstn == 1'b0)
        begin
            frame_cnt <= 32'd0;
            line_cnt  <= 10'd0;
            local_frame_seq <= 32'd0;
            last_line_id    <= 10'd0;
            frame_seq_init  <= 1'b0;
            packet_frame_id <= 32'd0;
            packet_line_id  <= 10'd0;
        end
        else begin
            if (active_line_valid) begin
                if ((tx_line_id == 10'd0) && ((last_line_id != 10'd0) || (~frame_seq_init))) begin
                    if (frame_seq_init)
                        local_frame_seq <= local_frame_seq + 1'b1;
                    else begin
                        local_frame_seq <= 32'd0;
                        frame_seq_init  <= 1'b1;
                    end
                end
                last_line_id <= tx_line_id;
            end

            if ((state == GEN_REQ) && udp_ram_data_req) begin
                packet_frame_id <= tx_frame_id;
                packet_line_id  <= tx_line_id;
                frame_cnt       <= tx_frame_id;
                line_cnt        <= tx_line_id;
            end
        end
    end

    always @(posedge rgmii_clk)
    begin
        if(rstn == 1'b0)
        begin
            write_end       <= 1'b0;
            ram_wr_data     <= 8'd0;
            ram_wr_en       <= 1'b0;
            packet_byte_cnt <= 11'd0;
            src_line_consume<= 1'b0;
        end
        else if (state == WRITE_RAM)
        begin
            if(packet_byte_cnt < UDP_PACKET_BYTES)
            begin
                ram_wr_en          <= 1'b1;
                write_end          <= (packet_byte_cnt == UDP_PACKET_BYTES - 1);
                src_line_consume   <= (packet_byte_cnt == UDP_PACKET_BYTES - 1);

                case(packet_byte_cnt)
                    11'd0   : ram_wr_data <= packet_frame_id[31:24];
                    11'd1   : ram_wr_data <= packet_frame_id[23:16];
                    11'd2   : ram_wr_data <= packet_frame_id[15:8];
                    11'd3   : ram_wr_data <= packet_frame_id[7:0];
                    11'd4   : ram_wr_data <= {6'd0, packet_line_id[9:8]};
                    11'd5   : ram_wr_data <= packet_line_id[7:0];
                    default :
                    begin
                        if (payload_byte_idx[0] == 1'b0)
                            ram_wr_data <= active_pixel_data[15:8];
                        else
                            ram_wr_data <= active_pixel_data[7:0];
                    end
                endcase

                packet_byte_cnt <= packet_byte_cnt + 1'b1;
            end
            else
            begin
                ram_wr_en        <= 1'b0;
                write_end        <= 1'b0;
                ram_wr_data      <= 8'd0;
                src_line_consume <= 1'b0;
            end
        end
        else
        begin
            write_end       <= 1'b0;
            ram_wr_data     <= 8'd0;
            ram_wr_en       <= 1'b0;
            packet_byte_cnt <= 11'd0;
            src_line_consume<= 1'b0;
        end
    end

endmodule
