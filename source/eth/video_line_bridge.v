`timescale 1ns / 1ps

module video_line_bridge #(
    parameter integer IMG_WIDTH  = 640,
    parameter integer IMG_HEIGHT = 640
)(
    input                vid_clk,
    input                vid_rstn,
    input                vid_vs,
    input                vid_hs,
    input                vid_de,
    input  [15:0]        vid_rgb565,

    input                rd_clk,
    input                rd_rstn,
    input                rd_line_consume,
    input  [9:0]         pixel_x,

    output reg           line_valid,
    output reg [31:0]    frame_id,
    output reg [9:0]     line_id,
    output reg [15:0]    pixel_data
);

    reg [15:0] line_buf0 [0:IMG_WIDTH-1];
    reg [15:0] line_buf1 [0:IMG_WIDTH-1];

    reg        vid_vs_d;
    reg        vid_de_d;
    reg [10:0] wr_x;
    reg        wr_buf_sel;
    reg        frame_start_pending;
    reg [31:0] src_frame_id;
    reg [31:0] cap_frame_id;
    reg [9:0]  src_line_id;
    reg [9:0]  cap_line_id;

    reg        wr_line_toggle;
    reg        ack_toggle_sync1;
    reg        ack_toggle_sync2;
    reg        publish_buf_sel;
    reg [31:0] publish_frame_id;
    reg [9:0]  publish_line_id;

    reg        rd_buf_sel;
    reg        line_toggle_sync1;
    reg        line_toggle_sync2;
    reg        line_toggle_sync2_d;
    reg        rd_ack_toggle;

    wire        vid_vs_rise;
    wire        vid_de_rise;
    wire        vid_de_fall;
    wire [10:0] wr_addr;
    wire        line_pending;

    assign vid_vs_rise  = vid_vs & ~vid_vs_d;
    assign vid_de_rise  = vid_de & ~vid_de_d;
    assign vid_de_fall  = ~vid_de & vid_de_d;
    assign wr_addr      = vid_de_rise ? 11'd0 : wr_x;
    assign line_pending = (wr_line_toggle != ack_toggle_sync2);

    always @(posedge vid_clk)
    begin
        if (~vid_rstn)
        begin
            vid_vs_d            <= 1'b0;
            vid_de_d            <= 1'b0;
            wr_x                <= 11'd0;
            wr_buf_sel          <= 1'b0;
            frame_start_pending <= 1'b1;
            src_frame_id        <= 32'd0;
            cap_frame_id        <= 32'd0;
            src_line_id         <= 10'd0;
            cap_line_id         <= 10'd0;
            wr_line_toggle      <= 1'b0;
            ack_toggle_sync1    <= 1'b0;
            ack_toggle_sync2    <= 1'b0;
            publish_buf_sel     <= 1'b0;
            publish_frame_id    <= 32'd0;
            publish_line_id     <= 10'd0;
        end
        else
        begin
            vid_vs_d         <= vid_vs;
            vid_de_d         <= vid_de;
            ack_toggle_sync1 <= rd_ack_toggle;
            ack_toggle_sync2 <= ack_toggle_sync1;

            if (vid_vs_rise)
            begin
                if (~frame_start_pending)
                    src_frame_id <= src_frame_id + 1'b1;

                frame_start_pending <= 1'b1;
                src_line_id         <= 10'd0;
            end

            if (vid_de_rise)
            begin
                cap_frame_id <= src_frame_id;
                cap_line_id  <= src_line_id;

                if (frame_start_pending)
                    frame_start_pending <= 1'b0;
            end

            if (vid_de && (wr_addr < IMG_WIDTH))
            begin
                if (wr_buf_sel == 1'b0)
                    line_buf0[wr_addr] <= vid_rgb565;
                else
                    line_buf1[wr_addr] <= vid_rgb565;

                if (wr_addr < IMG_WIDTH - 1)
                    wr_x <= wr_addr + 1'b1;
                else
                    wr_x <= IMG_WIDTH[10:0];
            end

            if (vid_de_fall)
            begin
                wr_x <= 11'd0;

                if ((wr_x == IMG_WIDTH) && (~line_pending))
                begin
                    publish_buf_sel  <= wr_buf_sel;
                    publish_frame_id <= cap_frame_id;
                    publish_line_id  <= cap_line_id;
                    wr_line_toggle   <= ~wr_line_toggle;
                end

                wr_buf_sel <= ~wr_buf_sel;

                if (src_line_id == IMG_HEIGHT - 1)
                    src_line_id <= 10'd0;
                else
                    src_line_id <= src_line_id + 1'b1;
            end
        end
    end

    always @(posedge rd_clk)
    begin
        if (~rd_rstn)
        begin
            rd_buf_sel          <= 1'b0;
            line_toggle_sync1   <= 1'b0;
            line_toggle_sync2   <= 1'b0;
            line_toggle_sync2_d <= 1'b0;
            rd_ack_toggle       <= 1'b0;
            line_valid          <= 1'b0;
            frame_id            <= 32'd0;
            line_id             <= 10'd0;
        end
        else
        begin
            line_toggle_sync1 <= wr_line_toggle;
            line_toggle_sync2 <= line_toggle_sync1;

            if (line_toggle_sync2 != line_toggle_sync2_d)
            begin
                line_toggle_sync2_d <= line_toggle_sync2;
                rd_buf_sel          <= publish_buf_sel;
                frame_id            <= publish_frame_id;
                line_id             <= publish_line_id;
                line_valid          <= 1'b1;
            end
            else if (rd_line_consume && line_valid)
            begin
                rd_ack_toggle <= ~rd_ack_toggle;
                line_valid    <= 1'b0;
            end
        end
    end

    always @(*)
    begin
        if (pixel_x >= IMG_WIDTH)
            pixel_data = 16'd0;
        else if (rd_buf_sel == 1'b0)
            pixel_data = line_buf0[pixel_x];
        else
            pixel_data = line_buf1[pixel_x];
    end

endmodule
