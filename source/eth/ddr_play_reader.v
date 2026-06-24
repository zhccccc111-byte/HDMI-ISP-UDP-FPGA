`timescale 1ns / 1ps

module ddr_play_reader #(
    parameter [27:0] VIDEO_BASE_ADDR   = 28'd0,
    parameter integer IMG_WIDTH        = 640,
    parameter integer IMG_HEIGHT       = 640,
    parameter integer TOTAL_FRAMES     = 600,
    parameter integer AXI_DATA_WIDTH   = 256,
    parameter [27:0] FRAME_ADDR_STEP   = 28'd409600,
    parameter [27:0] LINE_ADDR_STEP    = 28'd640,
    parameter integer BEATS_PER_BURST  = (AXI_DATA_WIDTH >= 256) ? 8 : 16,
    parameter integer PIXELS_PER_BEAT  = AXI_DATA_WIDTH / 16,
    parameter integer BURSTS_PER_LINE  = IMG_WIDTH / PIXELS_PER_BEAT / BEATS_PER_BURST,
    parameter [7:0]  BURST_ADDR_STEP   = BEATS_PER_BURST * PIXELS_PER_BEAT
)(
    input                core_clk,
    input                core_rstn,
    input                ddr_init_done,
    input                pll_lock,
    input                play_enable,
    input                latest_frame_valid,
    input  [31:0]        latest_frame_id,
    input                latest_frame_slot,

    output reg [27:0]    axi_araddr,
    output reg           axi_aruser_ap,
    output reg [3:0]     axi_aruser_id,
    output reg [3:0]     axi_arlen,
    input                axi_arready,
    output reg           axi_arvalid,

    input  [AXI_DATA_WIDTH-1:0] axi_rdata,
    input  [3:0]         axi_rid,
    input                axi_rlast,
    input                axi_rvalid,

    input                line_buf_ready,
    output reg           line_buf_start,
    output reg [31:0]    line_buf_frame_id,
    output reg [9:0]     line_buf_line_id,
    output reg           line_buf_wr_en,
    output reg [6:0]     line_buf_wr_idx,
    output reg [AXI_DATA_WIDTH-1:0] line_buf_wr_data,
    output reg           line_buf_done,

    output reg [31:0]    dbg_frame_id,
    output reg [9:0]     dbg_line_id,
    output reg [2:0]     dbg_state
);

    localparam [2:0] S_WAIT_INIT = 3'd0;
    localparam [2:0] S_WAIT_BUF  = 3'd1;
    localparam [2:0] S_REQ_BURST = 3'd2;
    localparam [2:0] S_WAIT_AR   = 3'd3;
    localparam [2:0] S_RECV_DATA = 3'd4;
    localparam [2:0] S_LINE_DONE = 3'd5;

    localparam integer BEATS_PER_LINE = IMG_WIDTH / PIXELS_PER_BEAT;
    localparam [3:0]  AXI_ARLEN_VALUE = BEATS_PER_BURST - 1;

    reg [2:0]  state;
    reg [9:0]  cur_line_id;
    reg [2:0]  burst_idx;
    reg [6:0]  beat_idx_in_line;
    reg [4:0]  beat_idx_in_burst;
    reg [27:0] line_base_addr;
    reg        active_frame_valid;
    reg [31:0] active_frame_id;
    reg        active_frame_slot;
    reg        pending_frame_valid;
    reg [31:0] pending_frame_id;
    reg        pending_frame_slot;
    reg [31:0] seen_latest_frame_id;
    reg        have_seen_latest_frame;

    wire start_ok;
    wire last_burst;
    wire last_beat_in_burst;
    wire last_beat_in_line;
    wire [27:0] next_line_base_addr;
    wire [31:0] header_frame_id;
    wire       latest_frame_update;
    wire       load_pending_now;

    assign start_ok           = ddr_init_done & pll_lock & play_enable & line_buf_ready & active_frame_valid;
    assign last_burst         = (burst_idx == BURSTS_PER_LINE - 1);
    assign last_beat_in_burst = (beat_idx_in_burst == BEATS_PER_BURST - 1);
    assign last_beat_in_line  = (beat_idx_in_line == BEATS_PER_LINE - 1);
    assign header_frame_id    = active_frame_id;
    assign latest_frame_update = latest_frame_valid
                              && (~have_seen_latest_frame || (latest_frame_id != seen_latest_frame_id));
    assign load_pending_now    = pending_frame_valid
                              && (state == S_WAIT_BUF)
                              && (~active_frame_valid || (cur_line_id == 10'd0));
    assign next_line_base_addr = VIDEO_BASE_ADDR
                               + (active_frame_slot ? FRAME_ADDR_STEP : 28'd0)
                               + (cur_line_id  * LINE_ADDR_STEP);

    always @(posedge core_clk or negedge core_rstn) begin
        if (!core_rstn) begin
            state             <= S_WAIT_INIT;
            cur_line_id       <= 10'd0;
            burst_idx         <= 3'd0;
            beat_idx_in_line  <= 7'd0;
            beat_idx_in_burst <= 5'd0;
            line_base_addr    <= VIDEO_BASE_ADDR;
            active_frame_valid<= 1'b0;
            active_frame_id   <= 32'd0;
            active_frame_slot <= 1'b0;
            pending_frame_valid <= 1'b0;
            pending_frame_id  <= 32'd0;
            pending_frame_slot<= 1'b0;
            seen_latest_frame_id <= 32'd0;
            have_seen_latest_frame <= 1'b0;
            axi_araddr        <= 28'd0;
            axi_aruser_ap     <= 1'b0;
            axi_aruser_id     <= 4'd0;
            axi_arlen         <= AXI_ARLEN_VALUE;
            axi_arvalid       <= 1'b0;
            line_buf_start    <= 1'b0;
            line_buf_frame_id <= 32'd0;
            line_buf_line_id  <= 10'd0;
            line_buf_wr_en    <= 1'b0;
            line_buf_wr_idx   <= 7'd0;
            line_buf_wr_data  <= {AXI_DATA_WIDTH{1'b0}};
            line_buf_done     <= 1'b0;
            dbg_frame_id      <= 32'd0;
            dbg_line_id       <= 10'd0;
            dbg_state         <= S_WAIT_INIT;
        end else begin
            axi_aruser_ap  <= 1'b0;
            axi_aruser_id  <= 4'd0;
            axi_arlen      <= AXI_ARLEN_VALUE;
            line_buf_start <= 1'b0;
            line_buf_wr_en <= 1'b0;
            line_buf_done  <= 1'b0;
            dbg_state      <= state;
            dbg_frame_id   <= header_frame_id;
            dbg_line_id    <= cur_line_id;

            if (latest_frame_update) begin
                pending_frame_valid   <= 1'b1;
                pending_frame_id      <= latest_frame_id;
                pending_frame_slot    <= latest_frame_slot;
                seen_latest_frame_id  <= latest_frame_id;
                have_seen_latest_frame<= 1'b1;
            end

            if (load_pending_now) begin
                active_frame_valid <= 1'b1;
                active_frame_id    <= pending_frame_id;
                active_frame_slot  <= pending_frame_slot;
                pending_frame_valid<= 1'b0;
            end

            case (state)
                S_WAIT_INIT: begin
                    axi_arvalid      <= 1'b0;
                    burst_idx        <= 3'd0;
                    beat_idx_in_line <= 7'd0;
                    beat_idx_in_burst<= 5'd0;
                    line_base_addr   <= next_line_base_addr;
                    if (ddr_init_done && pll_lock)
                        state <= S_WAIT_BUF;
                end

                S_WAIT_BUF: begin
                    axi_arvalid    <= 1'b0;
                    line_base_addr <= next_line_base_addr;
                    if (start_ok) begin
                        burst_idx         <= 3'd0;
                        beat_idx_in_line  <= 7'd0;
                        beat_idx_in_burst <= 5'd0;
                        line_buf_start    <= 1'b1;
                        line_buf_frame_id <= header_frame_id;
                        line_buf_line_id  <= cur_line_id;
                        state             <= S_REQ_BURST;
                    end
                end

                S_REQ_BURST: begin
                    axi_araddr  <= line_base_addr + burst_idx * BURST_ADDR_STEP;
                    axi_arvalid <= 1'b1;
                    state       <= S_WAIT_AR;
                end

                S_WAIT_AR: begin
                    axi_arvalid <= 1'b1;
                    if (axi_arvalid && axi_arready) begin
                        axi_arvalid       <= 1'b0;
                        beat_idx_in_burst <= 5'd0;
                        state             <= S_RECV_DATA;
                    end
                end

                S_RECV_DATA: begin
                    if (axi_rvalid) begin
                        line_buf_wr_en   <= 1'b1;
                        line_buf_wr_idx  <= beat_idx_in_line;
                        line_buf_wr_data <= axi_rdata;

                        if (!last_beat_in_line)
                            beat_idx_in_line <= beat_idx_in_line + 1'b1;

                        if (last_beat_in_burst) begin
                            beat_idx_in_burst <= 5'd0;
                            if (last_burst)
                                state <= S_LINE_DONE;
                            else begin
                                burst_idx <= burst_idx + 1'b1;
                                state     <= S_REQ_BURST;
                            end
                        end else begin
                            beat_idx_in_burst <= beat_idx_in_burst + 1'b1;
                        end
                    end
                end

                S_LINE_DONE: begin
                    line_buf_done <= 1'b1;
                    burst_idx     <= 3'd0;

                    if (cur_line_id == IMG_HEIGHT - 1) begin
                        cur_line_id <= 10'd0;
                    end else begin
                        cur_line_id <= cur_line_id + 1'b1;
                    end

                    state <= S_WAIT_BUF;
                end

                default: begin
                    state <= S_WAIT_INIT;
                end
            endcase
        end
    end

endmodule
