`timescale 1ns / 1ps
module HDMI_IN_DDR3_gamma_top#(
	parameter MEM_ROW_ADDR_WIDTH   = 15         ,
	parameter MEM_COL_ADDR_WIDTH   = 10         ,
	parameter MEM_BADDR_WIDTH      = 3          ,
	parameter MEM_DQ_WIDTH         =  32        ,
	parameter MEM_DQS_WIDTH        =  32/8
)(
	input                                sys_clk              ,//27Mhz
    input                                clk_p ,
    input                                clk_n ,
    input                                rst_in ,

//DDR
    output                               mem_rst_n                 ,
    output                               mem_ck                    ,
    output                               mem_ck_n                  ,
    output                               mem_cke                   ,
    output                               mem_cs_n                  ,
    output                               mem_ras_n                 ,
    output                               mem_cas_n                 ,
    output                               mem_we_n                  ,
    output                               mem_odt                   ,
    output      [MEM_ROW_ADDR_WIDTH-1:0] mem_a                     ,
    output      [MEM_BADDR_WIDTH-1:0]    mem_ba                    ,
    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs                   ,
    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs_n                 ,
    inout       [MEM_DQ_WIDTH-1:0]       mem_dq                    ,
    output      [MEM_DQ_WIDTH/8-1:0]     mem_dm                    ,
    output reg                           heart_beat_led            ,
    output                               ddr_init_done             ,
    output                               init_over_rx              ,
//MS72xx       
    output                               rstn_out                  ,
    output                               hd_scl                ,
    inout                                hd_sda                ,
    output                               hdmi_int_led              ,//HDMI_OUT初始化完成

    //HDMI_in
    input             pixclk_in    ,                            
    input             vs_in    , 
    input             hs_in    , 
    input             de_in    ,
    input     [7:0]   r_in    , 
    input     [7:0]   g_in    , 
    input     [7:0]   b_in    , 
//HDMI_OUT
    output                               pix_clk   /*synthesis PAP_MARK_DEBUG="1"*/                ,//pixclk                           
    output    reg                           vs_out    /*synthesis PAP_MARK_DEBUG="1"*/                , 
    output    reg                           hs_out    /*synthesis PAP_MARK_DEBUG="1"*/                , 
    output    reg                           de_out    /*synthesis PAP_MARK_DEBUG="1"*/                ,
    output    reg    [7:0]                  r_out     /*synthesis PAP_MARK_DEBUG="1"*/                , 
    output    reg    [7:0]                  g_out     /*synthesis PAP_MARK_DEBUG="1"*/                , 
    output    reg    [7:0]                  b_out     /*synthesis PAP_MARK_DEBUG="1"*/    
);
/////////////////////////////////////////////////////////////////////////////////////
// ENABLE_DDR
    parameter CTRL_ADDR_WIDTH = MEM_ROW_ADDR_WIDTH + MEM_BADDR_WIDTH + MEM_COL_ADDR_WIDTH;//28
    parameter TH_1S = 27'd33000000;
/////////////////////////////////////////////////////////////////////////////////////
    reg  [15:0]                 rstn_1ms            ;
    wire[15:0]                  o_rgb565            ;

//axi bus   
    wire [CTRL_ADDR_WIDTH-1:0]  axi_awaddr                 ;
    wire                        axi_awuser_ap              ;
    wire [3:0]                  axi_awuser_id              ;
    wire [3:0]                  axi_awlen                  ;
    wire                        axi_awready                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire                        axi_awvalid                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire [MEM_DQ_WIDTH*8-1:0]   axi_wdata                  ;
    wire [MEM_DQ_WIDTH*8/8-1:0] axi_wstrb                  ;
    wire                        axi_wready                 ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire [3:0]                  axi_wusero_id              ;
    wire                        axi_wusero_last            ;
    wire [CTRL_ADDR_WIDTH-1:0]  axi_araddr                 ;
    wire                        axi_aruser_ap              ;
    wire [3:0]                  axi_aruser_id              ;
    wire [3:0]                  axi_arlen                  ;
    wire                        axi_arready                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire                        axi_arvalid                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire [MEM_DQ_WIDTH*8-1:0]   axi_rdata                   /* synthesis syn_keep = 1 */;
    wire                        axi_rvalid                  /* synthesis syn_keep = 1 */;
    wire [3:0]                  axi_rid                    ;
    wire                        axi_rlast                  ;
    reg  [26:0]                 cnt                        ;
    reg  [15:0]                 cnt_1                      ;
/////////////////////////////////////////////////////////////////////////////////////
//PLL
pll pll_gen_clk (
    .clkin1   (  sys_clk    ),//27MHz
    .clkout0  (  pix_clk    ),//148.5

    .lock (  locked     )
);


cfg_pll cfg_pll_inst (
  .clkout0(cfg_clk),    // output
  .lock(),          // output
  .clkin1(sys_clk)       // input
);



reg rstn_sys = 0, rstn_pixel = 0; 
always @(posedge sys_clk or negedge locked) begin if(~locked) rstn_sys <= 0; else rstn_sys <= 1; end
always @(posedge pix_clk or negedge locked) begin if(~locked) rstn_pixel <= 0; else rstn_pixel <= 1; end
/*
ms72xx_ctl ms72xx_ctl(
    .clk         (  cfg_clk    ), //input       clk,
    .rst_n       (  rstn_out   ), //input       rstn,
           
    .init_over_rx(  rx_init_done),                 
    .init_over   (  init_over  ), //output      init_over,
    .iic_scl     (  hd_scl    ), //output      iic_scl,
    .iic_sda     (  hd_sda    )  //inout       iic_sda
);
*/
ms72xx_ctl ms72xx_ctl(
    .clk         (  cfg_clk    ), //input       clk,
    .rst_n       (  rstn_out   ), //input       rstn,
                            
    .init_over   (  rx_init_done  ), //output      init_over,
    .iic_rx_scl  (  hd_scl ), //output      iic_scl,
    .iic_rx_sda  (  hd_sda ), //inout       iic_sda
    .iic_scl     (     ), //output      iic_scl,
    .iic_sda     (      )  //inout       iic_sda
);
    assign   init_over_rx = rx_init_done;
   assign    hdmi_int_led    =    rx_init_done; 
    
    always @(posedge cfg_clk)
    begin
    	if(!locked)
    	    rstn_1ms <= 16'd0;
    	else
    	begin
    		if(rstn_1ms == 16'h2710)
    		    rstn_1ms <= rstn_1ms;
    		else
    		    rstn_1ms <= rstn_1ms + 1'b1;
    	end
    end
    



    reg    rstn_d0;
    reg    rstn_d1;




    assign rstn_out = (rstn_1ms == 16'h2710);


 reg  rst_reg ;
    always @ (posedge sys_clk )
        if (~rst_in)
            rst_reg <= 1'b1 ;
        else
            rst_reg <= 1'b0 ;

wire    [15:0]    hdmi_data_in;
assign    hdmi_data_in = {r_in[7:3],g_in[7:2],b_in[7:3]};


//gamma矫正
wire    [7:0]    gamma_data_r;
wire    [7:0]    gamma_data_g;
wire    [7:0]    gamma_data_b;
wire             gamma_de;
gamma_lookuptable u_gamma_lookuptable_r(
    .video_clk  ( pixclk_in  ),
    .video_data ( r_in ),
    .video_de   ( de_in   ),
    .gamma_de   ( gamma_de   ),
    .gamma_data  ( gamma_data_r  )
);

gamma_lookuptable u_gamma_lookuptable_g(
    .video_clk  ( pixclk_in  ),
    .video_data ( g_in ),
    .video_de   ( de_in   ),
    .gamma_de   (    ),
    .gamma_data  ( gamma_data_g  )
);

gamma_lookuptable u_gamma_lookuptable_b(
    .video_clk  ( pixclk_in  ),
    .video_data ( b_in ),
    .video_de   ( de_in   ),
    .gamma_de   (    ),
    .gamma_data  ( gamma_data_b  )
);


wire gauss_vs;
wire gauss_de;
wire [7:0] gauss_r;
wire [7:0] gauss_g;
wire [7:0] gauss_b;


rgb_gauss u_rgb_gauss(
    .clk(pixclk_in)             ,
    .rst_n(rstn_out)           ,
    
    .pre_vsync(vs_in)       ,
    .pre_hsync(gamma_de)       ,
    .pre_href(gamma_de)        ,
    .pre_r(gamma_data_r)           ,
    .pre_g(gamma_data_g)           ,
    .pre_b(gamma_data_b)           ,

    .post_vsync( gauss_vs)     ,
    .post_hsync()      ,
    .post_href(  gauss_de)     ,
    .post_r(gauss_r)          ,
    .post_g(gauss_g)          ,
    .post_b(gauss_b)
);

wire csc_de;
wire csc_vs;
wire [7:0] csc_y;
wire [7:0] csc_u;
wire [7:0] csc_v;

isp_csc u_isp_csc(
	.pclk(pixclk_in ),
	.rst_n( rstn_out),

	.in_href(gauss_de ),
	.in_vsync(gauss_vs ),
	.in_r(gauss_r ),
	.in_g(gauss_g ),
	.in_b(gauss_b ),

	.out_href( csc_de),
	.out_vsync( csc_vs),
	.out_y( csc_y),
	.out_u(csc_u ),
	.out_v( csc_v)
);

wire ee_de;
wire ee_vs;
wire [7:0] ee_y;
wire [7:0] ee_u;
wire [7:0] ee_v;

isp_ee u_isp_ee(
	.pclk(pixclk_in ),
	.rst_n( rstn_out),

	.in_href(csc_de ),
	.in_vsync(csc_vs ),
	.in_y(csc_y ),
	.in_u(csc_u ),
	.in_v(csc_v ),

	.out_href( ee_de),
	.out_vsync( ee_vs),
	.out_y( ee_y),
	.out_u(ee_u ),
	.out_v( ee_v)
);

wire occ_de;
wire occ_vs;
wire [7:0] occ_r;
wire [7:0] occ_g;
wire [7:0] occ_b;

isp_occ u_isp_occ(
	.pclk(pixclk_in ),
	.rst_n( rstn_out),

	.in_href(ee_de ),
	.in_vsync(ee_vs ),
	.in_y(ee_y ),
	.in_u(ee_u ),
	.in_v(ee_v ),

	.out_href( occ_de),
	.out_vsync( occ_vs),
	.out_r( occ_r),
	.out_g(occ_g ),
	.out_b( occ_b)
);


wire process_vs;
wire process_de;
wire [7:0] sc_r;
wire [7:0] sc_g;
wire [7:0] sc_b;
wire [9:0] sc_x;
wire [8:0] sc_y;

scale3x_downsampler u_scale3x_downsampler (
    .rst_n          (rstn_out),
    .pix_clk_in     (pixclk_in),
    .in_r           (occ_r),
    .in_g           (occ_g),
    .in_b           (occ_b),
    .in_vsync_valid (occ_vs),
    .in_de          (occ_de),
    .sc_r           (sc_r),
    .sc_g           (sc_g),
    .sc_b           (sc_b),
    .sc_de          (process_de),
    .sc_vsync_pulse (process_vs),
    .sc_x           (sc_x),
    .sc_y           (sc_y)
);

wire    [15:0]    write_data;
assign    write_data    =    {sc_r[7:3], sc_g[7:2], sc_b[7:3]};
wire trig_vs;

    reg       frame=0;
	always @(posedge pixclk_in or negedge rstn_sys) //write frame next
		if(!rstn_sys)begin
			frame <= 0;
		end else if(!trig_vs)begin//write frame next
	        frame <= ~frame;
            
	end


    wire write_vs;
    wire write_de;
    wire de_o;
    wire init_done;

    assign write_vs = frame&&process_vs;
    assign write_de = frame&&process_de;


	reg delay_vs=1'b0;
    reg delay_vs2=1'b0;
    reg trig_vs_tgl_pix = 1'b0;
    reg trig_vs_sync_ff1 = 1'b0;
    reg trig_vs_sync_ff2 = 1'b0;
    reg trig_vs_sync_ff3 = 1'b0;
    reg trig_vs_1_r = 1'b1;

	always @(posedge pixclk_in or negedge rstn_sys)begin
		if(!rstn_sys) begin
			delay_vs <= 1'b0;
		end
		else begin
			delay_vs <= process_vs;
		end
	end

	assign trig_vs = (~process_vs) || (delay_vs);//negetive trig

    always @(posedge pixclk_in or negedge rstn_sys) begin
        if(!rstn_sys)
            trig_vs_tgl_pix <= 1'b0;
        else if(!trig_vs)
            trig_vs_tgl_pix <= ~trig_vs_tgl_pix;
    end

    always @(posedge pix_clk or negedge rstn_sys) begin
        if(!rstn_sys) begin
            trig_vs_sync_ff1 <= 1'b0;
            trig_vs_sync_ff2 <= 1'b0;
            trig_vs_sync_ff3 <= 1'b0;
            trig_vs_1_r <= 1'b1;
        end else begin
            trig_vs_sync_ff1 <= trig_vs_tgl_pix;
            trig_vs_sync_ff2 <= trig_vs_sync_ff1;
            trig_vs_sync_ff3 <= trig_vs_sync_ff2;
            trig_vs_1_r <= (trig_vs_sync_ff3 ^ trig_vs_sync_ff2) ? 1'b0 : 1'b1;
        end
    end

    wire trig_vs_1;
    assign trig_vs_1 = frame? trig_vs_1_r:trig_vs_1;


    wire [11:0] hreal=640;
	wire [11:0] vreal=360;
    wire [15:0] lcd_data;
wire    vs_reg;
wire    hs_reg;
wire    de_reg ;
wire [15:0] rgb_reg;

    lcd_driver u_lcd_driver
	(
	    //  global clock
	    .clk        (pix_clk   ),
	    .rst_n      (rstn_pixel), 
	    
	    .lcd_dclk   (               ),
	    .lcd_sync   (               ),
	    .lcd_request(lcd_request    ), 	//	Request data 2 cycle ahead. 
	    //.lcd_hs     (lcd_hs         ),
	    .lcd_vs     (vs_reg         ),
        
	    .lcd_hs     (hs_reg         ),
	    .lcd_en     (de_reg         ),
	    .lcd_rgb    (rgb_reg),

		.H_REAL     (hreal),
		.V_REAL     (vreal),
	    //  user interface 
	    .lcd_data   (lcd_data),
		.trig_vs(trig_vs_1)//
	);

//////////////////////////////////////////////////////////////////////////////////////////////////////////
//修改ddr读写模块v1
    fram_buf fram_buf(
        .ddr_clk        (  core_clk             ),//input                         ddr_clk,
        .ddr_rstn       (  ddr_init_done        ),//input                         ddr_rstn,
        //data_in                                  
        .vin_clk        (  pixclk_in         ),//input                         vin_clk,
        .wr_fsync       (  ~write_vs           ),//input                         wr_fsync,
        .wr_en          (  write_de           ),//input                         wr_en,
        .wr_data        (  write_data             ),//input  [15 : 0]  wr_data,
        //data_out
        .vout_clk       (  pix_clk              ),//input                         vout_clk,
        .rd_fsync       (  vs_reg               ),//input                         rd_fsync,
        .rd_en          (  lcd_request                ),//input                         rd_en,
        .vout_de        (  de_o               ),//output                        vout_de,
        .vout_data      (  lcd_data             ),//output [PIX_WIDTH- 1'b1 : 0]  vout_data,
        .init_done      (  init_done            ),//output reg                    init_done,
        //axi bus
        .axi_awaddr     (  axi_awaddr           ),// output[27:0]
        .axi_awid       (  axi_awuser_id        ),// output[3:0]
        .axi_awlen      (  axi_awlen            ),// output[3:0]
        .axi_awsize     (                       ),// output[2:0]
        .axi_awburst    (                       ),// output[1:0]
        .axi_awready    (  axi_awready          ),// input
        .axi_awvalid    (  axi_awvalid          ),// output               
        .axi_wdata      (  axi_wdata            ),// output[255:0]
        .axi_wstrb      (  axi_wstrb            ),// output[31:0]
        .axi_wlast      (  axi_wusero_last      ),// input
        .axi_wvalid     (                       ),// output
        .axi_wready     (  axi_wready           ),// input
        .axi_bid        (  4'd0                 ),// input[3:0]
        .axi_araddr     (  axi_araddr           ),// output[27:0]
        .axi_arid       (  axi_aruser_id        ),// output[3:0]
        .axi_arlen      (  axi_arlen            ),// output[3:0]
        .axi_arsize     (                       ),// output[2:0]
        .axi_arburst    (                       ),// output[1:0]
        .axi_arvalid    (  axi_arvalid          ),// output
        .axi_arready    (  axi_arready          ),// input
        .axi_rready     (                       ),// output
        .axi_rdata      (  axi_rdata            ),// input[255:0]
        .axi_rvalid     (  axi_rvalid           ),// input
        .axi_rlast      (  axi_rlast            ),// input
        .axi_rid        (  axi_rid              ) // input[3:0]         
    );

   /*  always@(posedge pix_clk) begin
        r_out<=8'hff;
        g_out<=8'hff;
        b_out<=8'h00; 
        vs_out<=vs_o;
        hs_out<=hs_o;
        de_out<=de_re;
     end*/
//assign pix_clk = pixclk_in;
always  @(posedge pix_clk)begin


        vs_out       <=  vs_reg        ;
        hs_out       <=  hs_reg        ;
        de_out       <=  de_reg        ;
        r_out        <=  {rgb_reg[15:11],3'd0}         ;
        g_out        <=  {rgb_reg[10:5],2'd0}         ;
        b_out        <=  {rgb_reg[4:0],3'd0}         ;

end

////////////////////////////////////////////////////////////////////////////////////////////

wire clk_125Mhz ;

GTP_INBUFGDS #(
    .IOSTANDARD("DEFAULT"),
    .TERM_DIFF("ON")
) u_gtp (
    .O(clk_125Mhz), // OUTPUT  
    .I(clk_p), // INPUT  
    .IB(clk_n) // INPUT  
);

//ddr    
        ddr3_test u_ddr3_test_h (
             .ref_clk                   (clk_125Mhz            ),
             .resetn                    (rstn_out           ),// input
             .ddr_init_done             (ddr_init_done      ),// output

             .pll_lock                  (pll_lock           ),// output

             .core_clk                  (core_clk),                                  // output

             .phy_pll_lock              (phy_pll_lock),                          // output
             .gpll_lock                 (gpll_lock),                                // output
             .rst_gpll_lock             (rst_gpll_lock),                        // output
             .ddrphy_cpd_lock           (ddrphy_cpd_lock),                    // output
             //.ddr_init_done             (ddr_init_done),                        // output


             .axi_awaddr                (axi_awaddr         ),// input [27:0]
             .axi_awuser_ap             (1'b0               ),// input
             .axi_awuser_id             (axi_awuser_id      ),// input [3:0]
             .axi_awlen                 (axi_awlen          ),// input [3:0]
             .axi_awready               (axi_awready        ),// output
             .axi_awvalid               (axi_awvalid        ),// input
             .axi_wdata                 (axi_wdata          ),
             .axi_wstrb                 (axi_wstrb          ),// input [31:0]
             .axi_wready                (axi_wready         ),// output
             .axi_wusero_id             (                   ),// output [3:0]
             .axi_wusero_last           (axi_wusero_last    ),// output
             .axi_araddr                (axi_araddr         ),// input [27:0]
             .axi_aruser_ap             (1'b0               ),// input
             .axi_aruser_id             (axi_aruser_id      ),// input [3:0]
             .axi_arlen                 (axi_arlen          ),// input [3:0]
             .axi_arready               (axi_arready        ),// output
             .axi_arvalid               (axi_arvalid        ),// input
             .axi_rdata                 (axi_rdata          ),// output [255:0]
             .axi_rid                   (axi_rid            ),// output [3:0]
             .axi_rlast                 (axi_rlast          ),// output
             .axi_rvalid                (axi_rvalid         ),// output

             .apb_clk                   (1'b0               ),// input
             .apb_rst_n                 (1'b1               ),// input
             .apb_sel                   (1'b0               ),// input
             .apb_enable                (1'b0               ),// input
             .apb_addr                  (8'b0               ),// input [7:0]
             .apb_write                 (1'b0               ),// input
             .apb_ready                 (                   ), // output
             .apb_wdata                 (16'b0              ),// input [15:0]
             .apb_rdata                 (                   ),// output [15:0]
//             .apb_int                   (                   ),// output

             .mem_rst_n                 (mem_rst_n          ),// output
             .mem_ck                    (mem_ck             ),// output
             .mem_ck_n                  (mem_ck_n           ),// output
             .mem_cke                   (mem_cke            ),// output
             .mem_cs_n                  (mem_cs_n           ),// output
             .mem_ras_n                 (mem_ras_n          ),// output
             .mem_cas_n                 (mem_cas_n          ),// output
             .mem_we_n                  (mem_we_n           ),// output
             .mem_odt                   (mem_odt            ),// output
             .mem_a                     (mem_a              ),// output [14:0]
             .mem_ba                    (mem_ba             ),// output [2:0]
             .mem_dqs                   (mem_dqs            ),// inout [3:0]
             .mem_dqs_n                 (mem_dqs_n          ),// inout [3:0]
             .mem_dq                    (mem_dq             ),// inout [31:0]
             .mem_dm                    (mem_dm             ),// output [3:0]
             //debug

  .dbg_gate_start(1'b0),                      // input
  .dbg_cpd_start(1'b0),                        // input
  .dbg_ddrphy_rst_n(1'b1),                  // input
  .dbg_gpll_scan_rst(1'b0),                // input
  .samp_position_dyn_adj(1'b0),        // input
  .init_samp_position_even(32'd0),    // input [31:0]
  .init_samp_position_odd(32'd0),      // input [31:0]
  .wrcal_position_dyn_adj(1'b0),      // input
  .init_wrcal_position(32'd0),            // input [31:0]
  .force_read_clk_ctrl(1'b0),            // input
  .init_slip_step(16'd0),                      // input [15:0]
  .init_read_clk_ctrl(12'd0),              // input [11:0]
  .debug_calib_ctrl(),                  // output [33:0]
  .dbg_slice_status(),                  // output [67:0]
  .dbg_slice_state(),                    // output [87:0]
  .debug_data(),                              // output [275:0]
  .dbg_dll_upd_state(),                // output [1:0]
  .debug_gpll_dps_phase(),          // output [8:0]
  .dbg_rst_dps_state(),                // output [2:0]
  .dbg_tran_err_rst_cnt(),          // output [5:0]
  .dbg_ddrphy_init_fail(),          // output
  .debug_cpd_offset_adj(1'b0),          // input
  .debug_cpd_offset_dir(1'b0),          // input
  .debug_cpd_offset(10'd0),                  // input [9:0]
  .debug_dps_cnt_dir0(),              // output [9:0]
  .debug_dps_cnt_dir1(),              // output [9:0]
  .ck_dly_en(1'b0),                                // input
  .init_ck_dly_step(8'h0),                  // input [7:0]
  .ck_dly_set_bin(),                      // output [7:0]
  .align_error(),                            // output
  .debug_rst_state(),                    // output [3:0]
  .debug_cpd_state()                     // output [3:0]
       );

//心跳信号
     always@(posedge core_clk) begin
        if (!ddr_init_done)
            cnt <= 27'd0;
        else if ( cnt >= TH_1S )
            cnt <= 27'd0;
        else
            cnt <= cnt + 27'd1;
     end

     always @(posedge core_clk)
        begin
        if (!ddr_init_done)
            heart_beat_led <= 1'd1;
        else if ( cnt >= TH_1S )
            heart_beat_led <= ~heart_beat_led;
    end
                 
/////////////////////////////////////////////////////////////////////////////////////
endmodule
