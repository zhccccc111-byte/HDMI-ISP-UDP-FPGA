`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2019/03/13 23:18:52
// Design Name: 
// Module Name: gassin_filter
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

module gauss_filter #(
	parameter COL=640,
	parameter ROW=480
) 
(
	input 				clk			,
	input 				rst_n		,
	input               y_de		,
	input  [7:0] 		y_data		,
	output wire         	gauss_de	,
	output wire [7:0]    gauss_data   
);

	wire   [7:0]	matrix11     	 ;
	wire   [7:0]    matrix12     	 ;
	wire   [7:0]    matrix13     	 ;
		
	wire   [7:0]	matrix21     	 ;
	wire   [7:0]    matrix22     	 ;
	wire   [7:0]    matrix23     	 ;
		
	wire   [7:0]	matrix31     	 ;
	wire   [7:0]    matrix32     	 ;
	wire   [7:0]    matrix33     	 ;
		
	wire            matrix_de	 	 ;
		
	reg    [3:0]    matrix_de_r  	 ;
		
	reg    [15:0]   one_line     	 ;
	reg    [15:0]   second_line  	 ;
	reg    [15:0]   third_line   	 ;
		
	reg    [15:0]   add_line     	 ;

	reg    [15:0]   add_line_shift   ;

    reg       gauss_de_r;
    reg [7:0] gauss_data_r;

    assign gauss_de=gauss_de_r;
    assign gauss_data=gauss_data_r;


    matrix_3x3#(
    .IMG_WIDTH   ( 11'd1920 ),
    .IMG_HEIGHT  ( 11'd1080 )
)u_matrix_3x3(
    .video_clk   ( clk       ),
    .rst_n       ( rst_n   ),
   // .video_vs    ( in_vs        ),
    .video_de    ( y_de        ),
    .video_data  ( y_data      ),
    .matrix_de   ( matrix_de   ),
    .matrix11    ( matrix11    ),
    .matrix12    ( matrix12    ),
    .matrix13    ( matrix13    ),
    .matrix21    ( matrix21    ),
    .matrix22    ( matrix22    ),
    .matrix23    ( matrix23    ),
    .matrix31    ( matrix31    ),
    .matrix32    ( matrix32    ),
    .matrix33    ( matrix33    )
);

	always@(posedge clk)
		if(!rst_n)
			matrix_de_r	 <=  4'd0;
		else
			matrix_de_r	  <=  {matrix_de_r[2:0],matrix_de};
			
	always@(posedge clk)
		if(!rst_n)
			one_line <= 'd0;
		else if(matrix_de==1'b1)
			one_line <= matrix11+matrix12*2+matrix13;
		else	
			one_line <= 'd0;

	always@(posedge clk)
		if(!rst_n)
			second_line <= 'd0;
		else if(matrix_de==1'b1)
			second_line <= matrix21*2+matrix22*4+matrix23*2;
		else	
			second_line <='d0;				

	always@(posedge clk)
		if(!rst_n)
			third_line <= 'd0;
		else if(matrix_de==1'b1)
			third_line <= matrix31+matrix32*2+matrix33;
		else	
			third_line <='d0;
			
	always@(posedge clk)
		if(!rst_n)
			add_line <= 'd0;
		else if(matrix_de_r[0]==1'b1)
			add_line <= one_line+second_line+third_line;
		else	
			add_line <= 'd0;
			
	always@(posedge clk)
		if(!rst_n)
			add_line_shift <= 'd0;
		else if(matrix_de_r[1]==1'b1)
			add_line_shift <= add_line/16;
		else	
			add_line_shift <= 'd0;

	always@(posedge clk)
		if(!rst_n)
			gauss_de_r <= 1'b0;
		else 
			gauss_de_r <= matrix_de_r[2];
			
	always@(posedge clk)
		if(!rst_n)
			gauss_data_r <= 'd0;
		else if(matrix_de_r[2]==1'b1)
			gauss_data_r <= add_line_shift[7:0];
		else	
			gauss_data_r <='d0;
							

endmodule
