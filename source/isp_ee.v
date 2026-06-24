`timescale 1ns / 1ps

module isp_ee #(
    parameter BITS   = 8,
    parameter WIDTH  = 1920,
    parameter HEIGHT = 1080
) (
    input                  pclk,
    input                  rst_n,
    input                  in_href,
    input                  in_vsync,
    input  [BITS-1:0]      in_y,
    input  [BITS-1:0]      in_u,
    input  [BITS-1:0]      in_v,
    output                 out_href,
    output                 out_vsync,
    output [BITS-1:0]      out_y,
    output [BITS-1:0]      out_u,
    output [BITS-1:0]      out_v
);

localparam integer DLY_CLK = 6;

wire                matrix_de;
wire [BITS-1:0]     matrix11;
wire [BITS-1:0]     matrix12;
wire [BITS-1:0]     matrix13;
wire [BITS-1:0]     matrix21;
wire [BITS-1:0]     matrix22;
wire [BITS-1:0]     matrix23;
wire [BITS-1:0]     matrix31;
wire [BITS-1:0]     matrix32;
wire [BITS-1:0]     matrix33;

reg  [DLY_CLK-1:0]  href_dly;
reg  [DLY_CLK-1:0]  vsync_dly;
reg  [3:0]          matrix_de_dly;
reg  [BITS-1:0]     y_dly [0:DLY_CLK-1];
reg  [BITS-1:0]     u_dly [0:DLY_CLK-1];
reg  [BITS-1:0]     v_dly [0:DLY_CLK-1];
reg                 prev_out_href;
reg  [19:0]         out_h_count;

reg  signed [BITS+4:0] y_core;
reg  signed [BITS+4:0] y_edge;
reg  signed [BITS+5:0] y_data;
reg  [BITS-1:0]        sharp_y;
reg  [BITS-1:0]        out_y_r;

integer idx;

matrix_3x3 #(
    .IMG_WIDTH  ( WIDTH  ),
    .IMG_HEIGHT ( HEIGHT )
) u_matrix_3x3 (
    .video_clk  ( pclk     ),
    .rst_n      ( rst_n    ),
    .video_de   ( in_href   ),
    .video_data ( in_y      ),
    .matrix_de  ( matrix_de ),
    .matrix11   ( matrix11  ),
    .matrix12   ( matrix12  ),
    .matrix13   ( matrix13  ),
    .matrix21   ( matrix21  ),
    .matrix22   ( matrix22  ),
    .matrix23   ( matrix23  ),
    .matrix31   ( matrix31  ),
    .matrix32   ( matrix32  ),
    .matrix33   ( matrix33  )
);

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        href_dly      <= {DLY_CLK{1'b0}};
        vsync_dly     <= {DLY_CLK{1'b0}};
        matrix_de_dly <= 4'd0;
        for (idx = 0; idx < DLY_CLK; idx = idx + 1) begin
            y_dly[idx] <= {BITS{1'b0}};
            u_dly[idx] <= {BITS{1'b0}};
            v_dly[idx] <= {BITS{1'b0}};
        end
    end else begin
        href_dly      <= {href_dly[DLY_CLK-2:0], in_href};
        vsync_dly     <= {vsync_dly[DLY_CLK-2:0], in_vsync};
        matrix_de_dly <= {matrix_de_dly[2:0], matrix_de};

        y_dly[0] <= in_y;
        u_dly[0] <= in_u;
        v_dly[0] <= in_v;
        for (idx = 1; idx < DLY_CLK; idx = idx + 1) begin
            y_dly[idx] <= y_dly[idx-1];
            u_dly[idx] <= u_dly[idx-1];
            v_dly[idx] <= v_dly[idx-1];
        end
    end
end

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        y_core <= {(BITS+5){1'b0}};
        y_edge <= {(BITS+5){1'b0}};
    end else if (matrix_de) begin
        // Kernel:
        // -1 -1 -1
        // -1 12 -1
        // -1 -1 -1
        y_core <= {2'd0, matrix22, 3'd0} + {3'd0, matrix22, 2'd0};
        y_edge <= (({5'd0, matrix11} + {5'd0, matrix12}) + ({5'd0, matrix13} + {5'd0, matrix21}))
                + (({5'd0, matrix23} + {5'd0, matrix31}) + ({5'd0, matrix32} + {5'd0, matrix33}));
    end else begin
        y_core <= {(BITS+5){1'b0}};
        y_edge <= {(BITS+5){1'b0}};
    end
end

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        y_data <= {(BITS+6){1'b0}};
    end else if (matrix_de_dly[0]) begin
        y_data <= y_core - y_edge;
    end else begin
        y_data <= {(BITS+6){1'b0}};
    end
end

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        sharp_y <= {BITS{1'b0}};
    end else if (matrix_de_dly[1]) begin
        if (y_data < 0)
            sharp_y <= {BITS{1'b0}};
        else if (y_data > ((1 << (BITS + 2)) - 1))
            sharp_y <= {BITS{1'b1}};
        else
            sharp_y <= y_data[BITS+1:2];
    end else begin
        sharp_y <= {BITS{1'b0}};
    end
end

assign out_href  = href_dly[DLY_CLK-1];
assign out_vsync = vsync_dly[DLY_CLK-1];

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n)
        prev_out_href <= 1'b0;
    else
        prev_out_href <= out_href;
end

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n)
        out_h_count <= 20'd0;
    else if (in_vsync)
        out_h_count <= 20'd0;
    else if (prev_out_href && ~out_href)
        out_h_count <= out_h_count + 20'd1;
end

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        out_y_r <= {BITS{1'b0}};
    end else if (matrix_de_dly[2]) begin
        if ((out_h_count == 20'd0) || (out_h_count == 20'd1) || (out_h_count == HEIGHT-1))
            out_y_r <= y_dly[DLY_CLK-2];
        else
            out_y_r <= sharp_y;
    end else begin
        out_y_r <= {BITS{1'b0}};
    end
end

assign out_y = out_href ? out_y_r             : {BITS{1'b0}};
assign out_u = out_href ? u_dly[DLY_CLK-1]    : {BITS{1'b0}};
assign out_v = out_href ? v_dly[DLY_CLK-1]    : {BITS{1'b0}};

endmodule
