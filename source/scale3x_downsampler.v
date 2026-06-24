
module scale3x_downsampler #(
    parameter integer IN_W  = 1920,
    parameter integer IN_H  = 1080,
    parameter integer OUT_W = 640,
    parameter integer OUT_H = 360
) (
    input  wire       rst_n,
    input  wire       pix_clk_in,

    input  wire [7:0] in_r,
    input  wire [7:0] in_g,
    input  wire [7:0] in_b,
    input  wire       in_vsync_valid,
    input  wire       in_de,

    output reg  [7:0] sc_r,
    output reg  [7:0] sc_g,
    output reg  [7:0] sc_b,
    output reg        sc_de,
    output reg        sc_vsync_pulse,
    output reg  [9:0] sc_x,
    output reg  [8:0] sc_y
);

    reg in_de_d;
    reg in_vsync_d;

    reg [1:0] x_mod3;
    reg [1:0] y_mod3;

    reg [9:0] sc_x_cnt;
    reg [8:0] sc_y_cnt;


    wire de_rise    = in_de & ~in_de_d;
    wire de_fall    = ~in_de & in_de_d;
    wire vsync_rise = in_vsync_valid & ~in_vsync_d;

    wire sample_now = in_de && (x_mod3 == 2'd0) && (y_mod3 == 2'd0);

    always @(posedge pix_clk_in or negedge rst_n) begin
        if (!rst_n) begin
            in_de_d             <= 1'b0;
            in_vsync_d          <= 1'b0;

            x_mod3              <= 2'd0;
            y_mod3              <= 2'd0;
            sc_x_cnt            <= 10'd0;
            sc_y_cnt            <= 9'd0;

            sc_r                <= 8'd0;
            sc_g                <= 8'd0;
            sc_b                <= 8'd0;
            sc_de               <= 1'b0;
            sc_vsync_pulse      <= 1'b0;
            sc_x                <= 10'd0;
            sc_y                <= 9'd0;
        end else begin
            // Default one-cycle pulse/data valid outputs.
            sc_de          <= 1'b0;
            sc_vsync_pulse <= 1'b0;

            // Frame boundary: reset scaler row state and arm output frame pulse.
            if (vsync_rise) begin
                y_mod3              <= 2'd0;
                sc_y_cnt            <= 9'd0;
            end

            // Start of each input line.
            if (de_rise) begin
                x_mod3   <= 2'd0;
                sc_x_cnt <= 10'd0;
            end

            if (in_de) begin
                if (sample_now) begin
                    sc_r  <= in_r;
                    sc_g  <= in_g;
                    sc_b  <= in_b;
                    sc_de <= 1'b1;

                    sc_x  <= sc_x_cnt;
                    sc_y  <= sc_y_cnt;

                    // Emit frame pulse on first sampled pixel of a new frame.
                    

                    sc_x_cnt <= sc_x_cnt + 10'd1;
                end

                if (x_mod3 == 2'd2) begin
                    x_mod3 <= 2'd0;
                end else begin
                    x_mod3 <= x_mod3 + 2'd1;
                end
            end

            // End of each input line.
            if (de_fall) begin
                if (y_mod3 == 2'd0) begin
                    sc_y_cnt <= sc_y_cnt + 9'd1;
                end

                if (y_mod3 == 2'd2) begin
                    y_mod3 <= 2'd0;
                end else begin
                    y_mod3 <= y_mod3 + 2'd1;
                end
            end

            in_de_d    <= in_de;
            in_vsync_d <= in_vsync_valid;
            sc_vsync_pulse <= in_vsync_valid;

        end
    end

endmodule
