`timescale 1ns / 1ps

module ddr_play_line_bridge #(
    parameter integer IMG_WIDTH        = 640,
    parameter integer SRC_HEIGHT       = 360,
    parameter integer IMG_HEIGHT       = 640,
    parameter integer FRAME_PERIOD_CNT = 2083333,
    parameter integer BEAT_DATA_WIDTH  = 256,
    parameter [15:0]  PAD_RGB565       = 16'h8410
)(
    input                wr_clk,
    input                wr_rstn,
    input                line_buf_start,
    input  [31:0]        line_buf_frame_id,
    input  [9:0]         line_buf_line_id,
    input                line_buf_wr_en,
    input  [6:0]         line_buf_wr_idx,
    input  [BEAT_DATA_WIDTH-1:0] line_buf_wr_data,
    input                line_buf_done,
    output               line_buf_ready,

    input                rd_clk,
    input                rd_rstn,
    input                rd_line_consume,
    input  [9:0]         pixel_x,
    output reg           line_valid,
    output reg [31:0]    frame_id,
    output reg [9:0]     line_id,
    output reg [15:0]    pixel_data
);

    localparam integer PIXELS_PER_AXI_BEAT    = BEAT_DATA_WIDTH / 16;
    localparam integer AXI_BEATS_PER_LINE     = IMG_WIDTH / PIXELS_PER_AXI_BEAT;
    localparam integer LINE_WORDS             = IMG_WIDTH / 2;
    localparam integer LINE_WORD_ADDR_WIDTH   = 9;
    localparam integer LINE_BUF_WR_ADDR_WIDTH = 9;
    localparam integer LINE_BUF_RD_ADDR_WIDTH = 12;
    localparam integer LINE_STEP_CNT          = FRAME_PERIOD_CNT / IMG_HEIGHT;
    localparam integer LINE_STEP_REM          = FRAME_PERIOD_CNT % IMG_HEIGHT;
    localparam integer META_DATA_WIDTH        = 42;
    localparam integer TOP_PAD_LINES          = (IMG_HEIGHT - SRC_HEIGHT) / 2;
    localparam integer ACTIVE_END_LINE        = TOP_PAD_LINES + SRC_HEIGHT;

    wire [LINE_BUF_WR_ADDR_WIDTH-1:0] wr_addr_ext;
    wire [LINE_BUF_RD_ADDR_WIDTH-1:0] rd_addr_ext;
    wire                              line_buf0_wr_en;
    wire                              line_buf1_wr_en;
    wire [31:0]                       line_buf0_rd_word;
    wire [31:0]                       line_buf1_rd_word;
    wire [31:0]                       rd_word_mux;
    wire                              line_meta_wr_en;
    wire [0:0]                        line_meta_wr_addr;
    wire [0:0]                        line_meta_rd_addr;
    wire [META_DATA_WIDTH-1:0]        line_meta_wr_data;
    wire [META_DATA_WIDTH-1:0]        line_meta_rd_data;

    reg        wr_buf_sel;
    reg [31:0] wr_cur_frame_id;
    reg [9:0]  wr_cur_line_id;
    (* keep = "true" *) reg                        wr_pipe_wr_en;
    (* keep = "true" *) reg [6:0]                  wr_pipe_wr_idx;
    (* keep = "true" *) reg [BEAT_DATA_WIDTH-1:0]  wr_pipe_wr_data;
    reg        wr_done_pending;
    reg        wr_done_buf_sel;
    reg [31:0] wr_done_frame_id;
    reg [9:0]  wr_done_line_id;
    reg        publish_buf_sel;
    reg        wr_line_toggle;
    (* async_reg = "true" *) reg ack_toggle_sync1;
    (* async_reg = "true" *) reg ack_toggle_sync2;

    (* async_reg = "true" *) reg line_toggle_sync1;
    (* async_reg = "true" *) reg line_toggle_sync2;
    reg        line_toggle_sync2_d;
    reg        rd_ack_toggle;
    (* async_reg = "true" *) reg publish_buf_sel_sync1;
    (* async_reg = "true" *) reg publish_buf_sel_sync2;
    reg        pending_valid;
    reg        pending_buf_sel;
    reg [31:0] pending_frame_id;
    reg [9:0]  pending_line_id;
    reg        meta_capture_pending;
    reg [0:0]  meta_rd_addr_reg;
    reg        active_buf_sel;
    reg [31:0] frame_cycle_cnt;
    reg [31:0] next_line_release_cnt;
    reg [9:0]  line_step_err_cnt;
    reg        frame_init;
    reg [LINE_WORD_ADDR_WIDTH-1:0] rd_word_addr_reg;
    reg        cache_stream_loading;
    reg        cache_loaded;
    reg [1:0]  cache_load_state;
    reg [LINE_WORD_ADDR_WIDTH-1:0] load_word_idx;
    reg [31:0] load_word_data;
    reg [9:0]  cache_pixel_wr_idx;
    reg        active_is_pad;
    reg        output_frame_valid;
    reg [31:0] output_frame_id;
    reg [9:0]  out_line_id;
    reg [15:0] pixel_cache [0:IMG_WIDTH-1];

    wire                              line_pending;
    wire [10:0]                       next_line_step_err_sum;
    wire                              next_line_add_extra_cycle;
    wire                              output_pad_line;
    wire                              output_src_line;
    wire [9:0]                        expected_src_line_id;
    wire                              src_line_matches;

    localparam [1:0] LOAD_IDLE  = 2'd0;
    localparam [1:0] LOAD_REQ   = 2'd1;
    localparam [1:0] LOAD_WRITE0= 2'd2;
    localparam [1:0] LOAD_WRITE1= 2'd3;

    assign line_pending              = (wr_line_toggle != ack_toggle_sync2);
    assign line_buf_ready            = ~line_pending & ~wr_done_pending;
    assign next_line_step_err_sum    = line_step_err_cnt + LINE_STEP_REM;
    assign next_line_add_extra_cycle = (next_line_step_err_sum >= IMG_HEIGHT);
    assign wr_addr_ext               = {{(LINE_BUF_WR_ADDR_WIDTH-7){1'b0}}, wr_pipe_wr_idx};
    assign rd_addr_ext               = {{(LINE_BUF_RD_ADDR_WIDTH-LINE_WORD_ADDR_WIDTH){1'b0}}, rd_word_addr_reg};
    assign line_buf0_wr_en           = wr_pipe_wr_en && (wr_pipe_wr_idx < AXI_BEATS_PER_LINE) && (wr_buf_sel == 1'b0);
    assign line_buf1_wr_en           = wr_pipe_wr_en && (wr_pipe_wr_idx < AXI_BEATS_PER_LINE) && (wr_buf_sel == 1'b1);
    assign line_meta_wr_en           = wr_done_pending && ~line_pending;
    assign line_meta_wr_addr         = wr_done_buf_sel;
    assign line_meta_rd_addr         = meta_rd_addr_reg;
    assign line_meta_wr_data         = {wr_done_frame_id, wr_done_line_id};
    assign rd_word_mux               = (active_buf_sel == 1'b0) ? line_buf0_rd_word : line_buf1_rd_word;
    assign output_pad_line           = (out_line_id < TOP_PAD_LINES) || (out_line_id >= ACTIVE_END_LINE);
    assign output_src_line           = (out_line_id >= TOP_PAD_LINES) && (out_line_id < ACTIVE_END_LINE);
    assign expected_src_line_id      = out_line_id - TOP_PAD_LINES;
    assign src_line_matches          = pending_valid && (pending_line_id == expected_src_line_id);

    rd_fram_buf u_line_buf0 (
        .wr_data ( wr_pipe_wr_data   ),
        .wr_addr ( wr_addr_ext       ),
        .wr_en   ( line_buf0_wr_en   ),
        .wr_clk  ( wr_clk            ),
        .wr_rst  ( ~wr_rstn          ),
        .rd_data ( line_buf0_rd_word ),
        .rd_addr ( rd_addr_ext       ),
        .rd_clk  ( rd_clk            ),
        .rd_rst  ( ~rd_rstn          )
    );

    rd_fram_buf u_line_buf1 (
        .wr_data ( wr_pipe_wr_data   ),
        .wr_addr ( wr_addr_ext       ),
        .wr_en   ( line_buf1_wr_en   ),
        .wr_clk  ( wr_clk            ),
        .wr_rst  ( ~wr_rstn          ),
        .rd_data ( line_buf1_rd_word ),
        .rd_addr ( rd_addr_ext       ),
        .rd_clk  ( rd_clk            ),
        .rd_rst  ( ~rd_rstn          )
    );

    ddr_play_line_ram #(
        .ADDR_WIDTH ( 1               ),
        .DATA_WIDTH ( META_DATA_WIDTH )
    ) u_line_meta_ram (
        .wr_clk  ( wr_clk            ),
        .wr_en   ( line_meta_wr_en   ),
        .wr_addr ( line_meta_wr_addr ),
        .wr_data ( line_meta_wr_data ),
        .rd_clk  ( rd_clk            ),
        .rd_rstn ( rd_rstn           ),
        .rd_addr ( line_meta_rd_addr ),
        .rd_data ( line_meta_rd_data )
    );

    always @(posedge wr_clk or negedge wr_rstn) begin
        if (!wr_rstn) begin
            wr_buf_sel       <= 1'b0;
            wr_cur_frame_id  <= 32'd0;
            wr_cur_line_id   <= 10'd0;
            wr_pipe_wr_en    <= 1'b0;
            wr_pipe_wr_idx   <= 7'd0;
            wr_pipe_wr_data  <= {BEAT_DATA_WIDTH{1'b0}};
            wr_done_pending  <= 1'b0;
            wr_done_buf_sel  <= 1'b0;
            wr_done_frame_id <= 32'd0;
            wr_done_line_id  <= 10'd0;
            publish_buf_sel  <= 1'b0;
            wr_line_toggle   <= 1'b0;
            ack_toggle_sync1 <= 1'b0;
            ack_toggle_sync2 <= 1'b0;
        end else begin
            ack_toggle_sync1 <= rd_ack_toggle;
            ack_toggle_sync2 <= ack_toggle_sync1;

            wr_pipe_wr_en   <= line_buf_wr_en;
            wr_pipe_wr_idx  <= line_buf_wr_idx;
            wr_pipe_wr_data <= line_buf_wr_data;

            if (line_buf_start) begin
                wr_cur_frame_id <= line_buf_frame_id;
                wr_cur_line_id  <= line_buf_line_id;
            end

            if (line_buf_done) begin
                wr_done_pending  <= 1'b1;
                wr_done_buf_sel  <= wr_buf_sel;
                wr_done_frame_id <= wr_cur_frame_id;
                wr_done_line_id  <= wr_cur_line_id;
            end

            if (wr_done_pending && ~line_pending) begin
                publish_buf_sel <= wr_done_buf_sel;
                wr_line_toggle  <= ~wr_line_toggle;
                wr_buf_sel      <= ~wr_buf_sel;
                wr_done_pending <= 1'b0;
            end
        end
    end

    always @(posedge rd_clk or negedge rd_rstn) begin
        if (!rd_rstn) begin
            line_toggle_sync1      <= 1'b0;
            line_toggle_sync2      <= 1'b0;
            line_toggle_sync2_d    <= 1'b0;
            rd_ack_toggle          <= 1'b0;
            publish_buf_sel_sync1  <= 1'b0;
            publish_buf_sel_sync2  <= 1'b0;
            pending_valid          <= 1'b0;
            pending_buf_sel        <= 1'b0;
            pending_frame_id       <= 32'd0;
            pending_line_id        <= 10'd0;
            meta_capture_pending   <= 1'b0;
            meta_rd_addr_reg       <= 1'b0;
            active_buf_sel         <= 1'b0;
            line_valid             <= 1'b0;
            frame_id               <= 32'd0;
            line_id                <= 10'd0;
            frame_cycle_cnt        <= 32'd0;
            next_line_release_cnt  <= 32'd0;
            line_step_err_cnt      <= 10'd0;
            frame_init             <= 1'b1;
            rd_word_addr_reg       <= {LINE_WORD_ADDR_WIDTH{1'b0}};
            cache_stream_loading   <= 1'b0;
            cache_loaded           <= 1'b0;
            cache_load_state       <= LOAD_IDLE;
            load_word_idx          <= {LINE_WORD_ADDR_WIDTH{1'b0}};
            load_word_data         <= 32'd0;
            cache_pixel_wr_idx     <= 10'd0;
            active_is_pad          <= 1'b0;
            output_frame_valid     <= 1'b0;
            output_frame_id        <= 32'd0;
            out_line_id            <= 10'd0;
        end else begin
            line_toggle_sync1     <= wr_line_toggle;
            line_toggle_sync2     <= line_toggle_sync1;
            publish_buf_sel_sync1 <= publish_buf_sel;
            publish_buf_sel_sync2 <= publish_buf_sel_sync1;

            if (frame_init || (frame_cycle_cnt == FRAME_PERIOD_CNT - 1)) begin
                frame_cycle_cnt       <= 32'd0;
                next_line_release_cnt <= 32'd0;
                line_step_err_cnt     <= 10'd0;
                frame_init            <= 1'b0;
                line_valid            <= 1'b0;
                active_is_pad         <= 1'b0;
                out_line_id           <= 10'd0;
                cache_stream_loading  <= 1'b0;
                cache_loaded          <= 1'b0;
                cache_load_state      <= LOAD_IDLE;
                load_word_idx         <= {LINE_WORD_ADDR_WIDTH{1'b0}};
                load_word_data        <= 32'd0;
                cache_pixel_wr_idx    <= 10'd0;
                rd_word_addr_reg      <= {LINE_WORD_ADDR_WIDTH{1'b0}};
                if (pending_valid) begin
                    output_frame_valid <= 1'b1;
                    output_frame_id    <= pending_frame_id;
                end else begin
                    output_frame_valid <= 1'b0;
                end
            end else begin
                frame_cycle_cnt <= frame_cycle_cnt + 1'b1;
            end

            if (cache_stream_loading) begin
                case (cache_load_state)
                    LOAD_REQ: begin
                        rd_word_addr_reg <= load_word_idx;
                        cache_load_state <= LOAD_WRITE0;
                    end

                    LOAD_WRITE0: begin
                        load_word_data <= rd_word_mux;
                        pixel_cache[cache_pixel_wr_idx] <= rd_word_mux[15:0];
                        cache_pixel_wr_idx <= cache_pixel_wr_idx + 1'b1;
                        cache_load_state <= LOAD_WRITE1;
                    end

                    LOAD_WRITE1: begin
                        pixel_cache[cache_pixel_wr_idx] <= load_word_data[31:16];

                        if (load_word_idx == LINE_WORDS - 1) begin
                            cache_stream_loading <= 1'b0;
                            cache_loaded         <= 1'b1;
                            cache_load_state     <= LOAD_IDLE;
                        end else begin
                            load_word_idx       <= load_word_idx + 1'b1;
                            cache_pixel_wr_idx  <= cache_pixel_wr_idx + 1'b1;
                            cache_load_state    <= LOAD_REQ;
                        end
                    end

                    default: begin
                        cache_load_state <= LOAD_REQ;
                    end
                endcase
            end

            if (meta_capture_pending) begin
                meta_capture_pending <= 1'b0;
                pending_valid        <= 1'b1;
                pending_frame_id     <= line_meta_rd_data[META_DATA_WIDTH-1:10];
                pending_line_id      <= line_meta_rd_data[9:0];
            end

            if (line_toggle_sync2 != line_toggle_sync2_d) begin
                line_toggle_sync2_d   <= line_toggle_sync2;
                pending_buf_sel       <= publish_buf_sel_sync2;
                meta_rd_addr_reg      <= publish_buf_sel_sync2;
                meta_capture_pending  <= 1'b1;
                cache_stream_loading  <= 1'b0;
                cache_loaded          <= 1'b0;
                cache_load_state      <= LOAD_IDLE;
                load_word_idx         <= {LINE_WORD_ADDR_WIDTH{1'b0}};
                load_word_data        <= 32'd0;
                cache_pixel_wr_idx    <= 10'd0;
                rd_word_addr_reg      <= {LINE_WORD_ADDR_WIDTH{1'b0}};
            end

            if (~output_frame_valid && pending_valid && (pending_line_id == 10'd0) &&
                (out_line_id == 10'd0) && (~line_valid)) begin
                output_frame_valid <= 1'b1;
                output_frame_id    <= pending_frame_id;
            end

            if (~cache_stream_loading && ~cache_loaded && ~line_valid &&
                output_src_line && src_line_matches) begin
                active_buf_sel        <= pending_buf_sel;
                rd_word_addr_reg      <= {LINE_WORD_ADDR_WIDTH{1'b0}};
                cache_stream_loading  <= 1'b1;
                cache_loaded          <= 1'b0;
                cache_load_state      <= LOAD_REQ;
                load_word_idx         <= {LINE_WORD_ADDR_WIDTH{1'b0}};
                load_word_data        <= 32'd0;
                cache_pixel_wr_idx    <= 10'd0;
            end

            if (~line_valid && output_frame_valid && output_pad_line &&
                (frame_cycle_cnt >= next_line_release_cnt)) begin
                frame_id      <= output_frame_id;
                line_id       <= out_line_id;
                line_valid    <= 1'b1;
                active_is_pad <= 1'b1;
            end else if (~line_valid && output_frame_valid && output_src_line &&
                src_line_matches && cache_loaded &&
                (frame_cycle_cnt >= next_line_release_cnt)) begin
                frame_id      <= output_frame_id;
                line_id       <= out_line_id;
                line_valid    <= 1'b1;
                active_is_pad <= 1'b0;
            end else if (rd_line_consume && line_valid) begin
                if (~active_is_pad) begin
                    rd_ack_toggle <= ~rd_ack_toggle;
                    pending_valid <= 1'b0;
                    cache_loaded  <= 1'b0;
                end

                line_valid            <= 1'b0;
                active_is_pad         <= 1'b0;
                next_line_release_cnt <= next_line_release_cnt + LINE_STEP_CNT + next_line_add_extra_cycle;

                if (next_line_add_extra_cycle)
                    line_step_err_cnt <= next_line_step_err_sum - IMG_HEIGHT;
                else
                    line_step_err_cnt <= next_line_step_err_sum;

                if (out_line_id == IMG_HEIGHT - 1) begin
                    out_line_id        <= 10'd0;
                    output_frame_valid <= 1'b0;
                end else begin
                    out_line_id <= out_line_id + 1'b1;
                end
            end
        end
    end

    always @(*) begin
        if ((pixel_x >= IMG_WIDTH) || (~line_valid))
            pixel_data = 16'd0;
        else if (active_is_pad)
            pixel_data = PAD_RGB565;
        else
            pixel_data = pixel_cache[pixel_x];
    end

endmodule

module ddr_play_line_ram #(
    parameter integer ADDR_WIDTH = 1,
    parameter integer DATA_WIDTH = 42
)(
    input                       wr_clk,
    input                       wr_en,
    input      [ADDR_WIDTH-1:0] wr_addr,
    input      [DATA_WIDTH-1:0] wr_data,
    input                       rd_clk,
    input                       rd_rstn,
    input      [ADDR_WIDTH-1:0] rd_addr,
    output reg [DATA_WIDTH-1:0] rd_data
)/* synthesis syn_ramstyle = "block_ram" */;

    reg [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH) - 1];

    always @(posedge wr_clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk or negedge rd_rstn) begin
        if (!rd_rstn)
            rd_data <= {DATA_WIDTH{1'b0}};
        else
            rd_data <= mem[rd_addr];
    end

endmodule
