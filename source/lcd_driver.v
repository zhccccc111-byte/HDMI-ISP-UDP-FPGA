/*-----------------------------------------------------------------------
								 \\\|///
							   \\  - -  //
								(  @ @  )
+-----------------------------oOOo-(_)-oOOo-----------------------------+
CONFIDENTIAL IN CONFIDENCE
This confidential and proprietary software may be only used as authorized
by a licensing agreement from CrazyBingo (Thereturnofbingo).
In the event of publication, the following notice is applicable:
Copyright (C) 2013-20xx CrazyBingo Corporation
The entire notice above must be reproduced on all authorized copies.
Author				:		CrazyBingo
Technology blogs 	: 		www.crazyfpga.com
Email Address 		: 		crazyfpga@vip.qq.com
Filename			:		lcd_driver.v
Date				:		2012-02-18
Description			:		LCD/VGA driver.
Modification History	:
Date			By			Version			Change Description
=========================================================================
12/02/18		CrazyBingo	1.0				Original
12/03/19		CrazyBingo	1.1				Modification
12/03/21		CrazyBingo	1.2				Modification
12/05/13		CrazyBingo	1.3				Modification
13/11/07		CrazyBingo	2.1				Modification
17/04/02		CrazyBingo	3.0				Modify for 12bit width logic
-------------------------------------------------------------------------
|                                     Oooo							|
+------------------------------oooO--(   )-----------------------------+
                              (   )   ) /
                               \ (   (_/
                                \_)
----------------------------------------------------------------------*/   

`timescale 1ns/1ps

`include "lcd_para.v"
//??????????vs??SYNC=5?????BACK=5????? DISP=640????? en??????งน???????????640*640
module lcd_driver #(
	//	Setting up default timing
	parameter 	H_FRONT	= `H_FRONT,
			H_SYNC 	= `H_SYNC,
			H_BACK 	= `H_BACK,
			H_DISP	= `H_DISP,
			H_TOTAL	= `H_TOTAL,
						
			V_FRONT	= `V_FRONT,
			V_SYNC 	= `V_SYNC,
			V_BACK 	= `V_BACK,
			V_DISP 	= `V_DISP,
			V_TOTAL	= `V_TOTAL,
			
			DATA_WIDTH 	= 16

			//H_REAL = 640,
			//V_REAL = 480
)(  	
	//global clock
	input					clk,			//system clock
	input					rst_n,     		//sync reset
	
	//lcd interface
	output				lcd_dclk,   	//lcd pixel clock
	output				lcd_sync,		//lcd sync
	output reg			lcd_vs,	    	//lcd vertical sync
    output reg			lcd_hs,
	output reg			lcd_en,			//lcd display enable
	output	[DATA_WIDTH-1:0]	lcd_rgb,		//lcd display data

	input [11:0]		H_REAL,
	input [11:0]		V_REAL,

	//user interface
	output reg			lcd_request,	//lcd data request
	input 	[DATA_WIDTH-1:0]	lcd_data,		//lcd data

	//output reg			frame_count
	//input [1:0]bf_process_vs
	input trig_vs
);	 
reg en;
reg [31:0] pixcnt;
/*******************************************
		SYNC--BACK--DISP--FRONT
*******************************************/
//------------------------------------------
//h_sync counter & generator
reg [13:0] hcnt; 
always @ (posedge clk or negedge rst_n or negedge trig_vs)
begin
	if ((!rst_n) || (!trig_vs))begin//reset???????hcnt=0
		hcnt <= 12'd0;
//		frame_count <= 1'b0;
	end
	else
		begin
        if(hcnt < H_TOTAL - 1'b1)		//line over			
            hcnt <= hcnt + 1'b1;
        else
            hcnt <= 12'd0;
		end
end 


//------------------------------------------
//v_sync counter & generator
reg [11:0] vcnt;
always@(posedge clk or negedge rst_n or negedge trig_vs)
begin
	if (!rst_n)begin
		vcnt <= 12'b0;
		en <= 0;
//		frame_count <= 1'b0;
	end else if(!trig_vs)begin
		vcnt <= 12'b0;
		en <= 1;		
	end
	else if(hcnt == H_TOTAL - 1'b1)		//line over
		begin
		if(vcnt < V_TOTAL - 1'b1)		//frame over
			vcnt <= vcnt + 1'b1;
		else begin
			vcnt <= 12'd0;
			en <= 0;
//			frame_count <= ~frame_count;
		end
		end
end

always@(posedge clk or negedge rst_n or negedge trig_vs)
begin
	if((!rst_n) || (!trig_vs))
		pixcnt <= 32'd0;
	else if(lcd_en)
		pixcnt <= pixcnt + 1'b1;
	else
		pixcnt <= pixcnt;
end

always@(posedge clk )
begin
	lcd_vs <= (en)? ((vcnt <= V_SYNC - 1'b1) ? 1'b0 : 1'b1) : 1'b0;
end

always@(posedge clk )
begin
	lcd_hs <= (en)? ((hcnt <= H_SYNC - 1'b1) ? 1'b0 : 1'b1) : 1'b0;
end

//------------------------------------------
//LCELL	LCELL(.in(clk),.out(lcd_dclk));
assign	lcd_dclk = ~clk;
assign	lcd_sync = 1'b0;


//-----------------------------------------
reg     [DATA_WIDTH-1:0]  r_lcd_rgb = 0; 
always@(posedge clk) begin
	lcd_en		<=	(en)?   ( (hcnt >= H_SYNC + H_BACK  && hcnt < H_SYNC + H_BACK + H_DISP) &&
						      (vcnt >= V_SYNC + V_BACK  && vcnt < V_SYNC + V_BACK + V_DISP) 
						      ? 1'b1 : 1'b0) : 1'b0;
    // r_lcd_rgb 	<= 	lcd_data;
	if(((hcnt >= H_SYNC + H_BACK  && hcnt < H_SYNC + H_BACK + H_DISP)&&(vcnt >= V_SYNC + V_BACK  && vcnt < V_SYNC + V_BACK + (V_DISP-V_REAL)/2))
		||((hcnt >= H_SYNC + H_BACK && hcnt < H_SYNC + H_BACK + H_DISP)&&(vcnt >= V_SYNC + V_BACK + (V_DISP+V_REAL)/2  && vcnt < V_SYNC + V_BACK + V_DISP)))
      begin
      r_lcd_rgb <= 16'h8410;
	end else if((hcnt >= H_SYNC + H_BACK  && hcnt < H_SYNC + H_BACK + H_DISP)
			&&(vcnt >= V_SYNC + V_BACK + (V_DISP-V_REAL)/2 && vcnt < V_SYNC + V_BACK + (V_DISP+V_REAL)/2))
	  begin
      r_lcd_rgb <= lcd_data;
	  end
end 
assign lcd_rgb = (lcd_en ? r_lcd_rgb : 0); 

//------------------------------------------
//ahead x clock
localparam	H_AHEAD = 	12'd3;


always@(posedge clk) begin
	//lcd_request	<=	(en)?  (((pixcnt >=((V_DISP-V_REAL)/2*H_DISP-H_AHEAD)) &&(pixcnt <= ((V_DISP + V_REAL)/2*H_DISP-H_AHEAD-1)))?  1'b1 : 1'b0) : 1'b0;
    lcd_request	<=	(en)?  ((hcnt >= H_SYNC + H_BACK - H_AHEAD + (H_DISP-H_REAL)/2 && hcnt < H_SYNC + H_BACK + (H_DISP+H_REAL)/2 - H_AHEAD) &&
						 	(vcnt >= V_SYNC + V_BACK + (V_DISP-V_REAL)/2 && vcnt < V_SYNC + V_BACK + (V_DISP+V_REAL)/2) 
						 	? 1'b1 : 1'b0) : 1'b0;
end

endmodule
