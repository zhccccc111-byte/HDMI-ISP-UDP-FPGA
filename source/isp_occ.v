`timescale 1ns / 1ps

module isp_occ #(
	parameter BITS = 8,
	parameter WIDTH = 1920,
	parameter HEIGHT = 1080
) (
	input pclk,
	input rst_n,

	input in_href,
	input in_vsync,
	input [BITS-1:0] in_y,
	input [BITS-1:0] in_u,
	input [BITS-1:0] in_v,

	output out_href,
	output out_vsync,
	output [BITS-1:0] out_r,
	output [BITS-1:0] out_g,
	output [BITS-1:0] out_b
);

	reg signed [BITS + 1:0] data_y;
	reg signed [BITS + 1:0] data_u;
	reg signed [BITS + 1:0] data_v;
	always @ (posedge pclk or negedge rst_n) begin
		if (!rst_n) begin
			data_y <= 0;
			data_u <= 0;
			data_v <= 0;
		end
		else begin
			data_y <= {2'b0, in_y};
			data_u <= {2'b0, in_u};
			data_v <= {2'b0, in_v};
		end
	end
	
	reg signed [BITS + 1:0] data_y_y;
	reg signed [BITS + 1:0] data_u_u;
	reg signed [BITS + 1:0] data_v_v;
	always @ (posedge pclk or negedge rst_n) begin
		if (!rst_n) begin
			data_y_y <= 0;
			data_u_u <= 0;
			data_v_v <= 0;
		end
		else begin
			data_y_y <= data_y;
			data_u_u <= data_u - 10'sd128;
			data_v_v <= data_v - 10'sd128;
		end
	end

	reg signed [BITS + 1 + 10:0] r_y, r_v;
	reg signed [BITS + 1 + 10:0] g_y, g_u, g_v;
	reg signed [BITS + 1 + 10:0] b_y, b_u;
	always @ (posedge pclk or negedge rst_n) begin
		if (!rst_n) begin
            r_y <= 0;
            r_v <= 0;
            g_y <= 0;
            g_u <= 0;
            g_v <= 0;
            b_y <= 0;
            b_u <= 0;
        end
        else begin
            r_y <= data_y_y <<< 8;
            r_v <= data_v_v * 10'sd359;
            g_y <= data_y_y <<< 8;
            g_u <= data_u_u * 10'sd88;	
            g_v <= data_v_v * 10'sd183;
            b_y <= data_y_y <<< 8;
            b_u <= data_u_u * 10'sd454;
        end
    end
    
    reg signed [BITS + 3 :0] data_r;
    reg signed [BITS + 3 :0] data_g;
    reg signed [BITS + 3 :0] data_b;
	always @ (posedge pclk or negedge rst_n) begin
		if (!rst_n) begin
            data_r <= 0;
            data_g <= 0;
            data_b <= 0;
        end
        else begin
            data_r <= (r_y + r_v) >>> 8;
            data_g <= (g_y - g_u - g_v) >>> 8;
            data_b <= (b_y + b_u) >>> 8;
        end
    end  
    
	localparam DLY_CLK = 4;
	reg [DLY_CLK-1:0] href_dly;
	reg [DLY_CLK-1:0] vsync_dly;
	always @ (posedge pclk or negedge rst_n) begin
		if (!rst_n) begin
			href_dly <= 0;
			vsync_dly <= 0;
		end
		else begin
			href_dly <= {href_dly[DLY_CLK-2:0], in_href};
			vsync_dly <= {vsync_dly[DLY_CLK-2:0], in_vsync};
		end
	end  
	
	assign out_href = href_dly[DLY_CLK-1];
	assign out_vsync = vsync_dly[DLY_CLK-1];
	assign out_r = out_href ? (data_r > 255 ? 255 : (data_r < 0 ? 0 : data_r[BITS - 1:0])) : {BITS{1'b0}};
	assign out_g = out_href ? (data_g > 255 ? 255 : (data_g < 0 ? 0 : data_g[BITS - 1:0])) : {BITS{1'b0}};
	assign out_b = out_href ? (data_b > 255 ? 255 : (data_b < 0 ? 0 : data_b[BITS - 1:0])) : {BITS{1'b0}};
endmodule
