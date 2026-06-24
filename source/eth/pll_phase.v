`timescale 1ns/10fs

// Logos2-compatible phase PLL for the 100Pro migration.
// Parameters are derived from the official 100Pro Ethernet reference GPLL.
module pll_phase (
    input  wire clkin1,
    output wire clkout0,
    output wire clkout1,
    output wire pll_lock
);

    localparam real    CLKIN_FREQ       = 125.0;
    localparam         LOCK_MODE        = 0;
    localparam integer STATIC_RATIOI    = 5;
    localparam integer STATIC_RATIOM    = 2;
    localparam real    STATIC_RATIO0    = 8.0;
    localparam integer STATIC_RATIO1    = 8;
    localparam integer STATIC_RATIO2    = 20;
    localparam integer STATIC_RATIO3    = 20;
    localparam integer STATIC_RATIO4    = 20;
    localparam integer STATIC_RATIO5    = 20;
    localparam integer STATIC_RATIO6    = 20;
    localparam real    STATIC_RATIOF    = 20.0;
    localparam integer STATIC_DUTY0     = 8;
    localparam integer STATIC_DUTY1     = 8;
    localparam integer STATIC_DUTY2     = 20;
    localparam integer STATIC_DUTY3     = 20;
    localparam integer STATIC_DUTY4     = 20;
    localparam integer STATIC_DUTY5     = 20;
    localparam integer STATIC_DUTY6     = 20;
    localparam integer STATIC_DUTYF     = 20;
    localparam integer STATIC_PHASE     = 0;
    localparam integer STATIC_PHASE0    = 5;
    localparam integer STATIC_PHASE1    = 5;
    localparam integer STATIC_PHASE2    = 0;
    localparam integer STATIC_PHASE3    = 0;
    localparam integer STATIC_PHASE4    = 0;
    localparam integer STATIC_PHASE5    = 0;
    localparam integer STATIC_PHASE6    = 0;
    localparam integer STATIC_PHASEF    = 0;
    localparam integer STATIC_CPHASE0   = 0;
    localparam integer STATIC_CPHASE1   = 2;
    localparam integer STATIC_CPHASE2   = 0;
    localparam integer STATIC_CPHASE3   = 0;
    localparam integer STATIC_CPHASE4   = 0;
    localparam integer STATIC_CPHASE5   = 0;
    localparam integer STATIC_CPHASE6   = 0;
    localparam integer STATIC_CPHASEF   = 0;
    localparam         CLK_DPS0_EN      = "FALSE";
    localparam         CLK_DPS1_EN      = "FALSE";
    localparam         CLK_DPS2_EN      = "FALSE";
    localparam         CLK_DPS3_EN      = "FALSE";
    localparam         CLK_DPS4_EN      = "FALSE";
    localparam         CLK_DPS5_EN      = "FALSE";
    localparam         CLK_DPS6_EN      = "FALSE";
    localparam         CLK_DPSF_EN      = "FALSE";
    localparam         CLK_CAS5_EN      = "FALSE";
    localparam         CLKOUT0_SYN_EN   = "FALSE";
    localparam         CLKOUT1_SYN_EN   = "FALSE";
    localparam         CLKOUT2_SYN_EN   = "FALSE";
    localparam         CLKOUT3_SYN_EN   = "FALSE";
    localparam         CLKOUT4_SYN_EN   = "FALSE";
    localparam         CLKOUT5_SYN_EN   = "FALSE";
    localparam         CLKOUT6_SYN_EN   = "FALSE";
    localparam         CLKOUTF_SYN_EN   = "FALSE";
    localparam         SSC_MODE         = "DISABLE";
    localparam real    SSC_FREQ         = 25;
    localparam         INTERNAL_FB      = "CLKOUTF";
    localparam         EXTERNAL_FB      = "DISABLE";
    localparam         BANDWIDTH        = "OPTIMIZED";

    wire       clkin2;
    wire       clkfb;
    wire       clkin_sel;
    wire       dps_clk;
    wire       dps_en;
    wire       dps_dir;
    wire       clkout0_syn;
    wire       clkout1_syn;
    wire       clkout2_syn;
    wire       clkout3_syn;
    wire       clkout4_syn;
    wire       clkout5_syn;
    wire       clkout6_syn;
    wire       clkoutf_syn;
    wire       pll_pwd;
    wire       rst;
    wire       apb_clk;
    wire       apb_rst_n;
    wire [4:0] apb_addr;
    wire       apb_sel;
    wire       apb_en;
    wire       apb_write;
    wire [15:0] apb_wdata;

    assign clkin2     = 1'b0;
    assign clkfb      = 1'b0;
    assign clkin_sel  = 1'b0;
    assign dps_clk    = 1'b0;
    assign dps_en     = 1'b0;
    assign dps_dir    = 1'b0;
    assign clkout0_syn = 1'b0;
    assign clkout1_syn = 1'b0;
    assign clkout2_syn = 1'b0;
    assign clkout3_syn = 1'b0;
    assign clkout4_syn = 1'b0;
    assign clkout5_syn = 1'b0;
    assign clkout6_syn = 1'b0;
    assign clkoutf_syn = 1'b0;
    assign pll_pwd    = 1'b0;
    assign rst        = 1'b0;
    assign apb_clk    = 1'b0;
    assign apb_rst_n  = 1'b0;
    assign apb_addr   = 5'd0;
    assign apb_sel    = 1'b0;
    assign apb_en     = 1'b0;
    assign apb_write  = 1'b0;
    assign apb_wdata  = 16'd0;

    GTP_GPLL #(
        .CLKIN_FREQ      (CLKIN_FREQ      ),
        .LOCK_MODE       (LOCK_MODE       ),
        .STATIC_RATIOI   (STATIC_RATIOI   ),
        .STATIC_RATIOM   (STATIC_RATIOM   ),
        .STATIC_RATIO0   (STATIC_RATIO0   ),
        .STATIC_RATIO1   (STATIC_RATIO1   ),
        .STATIC_RATIO2   (STATIC_RATIO2   ),
        .STATIC_RATIO3   (STATIC_RATIO3   ),
        .STATIC_RATIO4   (STATIC_RATIO4   ),
        .STATIC_RATIO5   (STATIC_RATIO5   ),
        .STATIC_RATIO6   (STATIC_RATIO6   ),
        .STATIC_RATIOF   (STATIC_RATIOF   ),
        .STATIC_DUTY0    (STATIC_DUTY0    ),
        .STATIC_DUTY1    (STATIC_DUTY1    ),
        .STATIC_DUTY2    (STATIC_DUTY2    ),
        .STATIC_DUTY3    (STATIC_DUTY3    ),
        .STATIC_DUTY4    (STATIC_DUTY4    ),
        .STATIC_DUTY5    (STATIC_DUTY5    ),
        .STATIC_DUTY6    (STATIC_DUTY6    ),
        .STATIC_DUTYF    (STATIC_DUTYF    ),
        .STATIC_PHASE    (STATIC_PHASE    ),
        .STATIC_PHASE0   (STATIC_PHASE0   ),
        .STATIC_PHASE1   (STATIC_PHASE1   ),
        .STATIC_PHASE2   (STATIC_PHASE2   ),
        .STATIC_PHASE3   (STATIC_PHASE3   ),
        .STATIC_PHASE4   (STATIC_PHASE4   ),
        .STATIC_PHASE5   (STATIC_PHASE5   ),
        .STATIC_PHASE6   (STATIC_PHASE6   ),
        .STATIC_PHASEF   (STATIC_PHASEF   ),
        .STATIC_CPHASE0  (STATIC_CPHASE0  ),
        .STATIC_CPHASE1  (STATIC_CPHASE1  ),
        .STATIC_CPHASE2  (STATIC_CPHASE2  ),
        .STATIC_CPHASE3  (STATIC_CPHASE3  ),
        .STATIC_CPHASE4  (STATIC_CPHASE4  ),
        .STATIC_CPHASE5  (STATIC_CPHASE5  ),
        .STATIC_CPHASE6  (STATIC_CPHASE6  ),
        .STATIC_CPHASEF  (STATIC_CPHASEF  ),
        .CLK_DPS0_EN     (CLK_DPS0_EN     ),
        .CLK_DPS1_EN     (CLK_DPS1_EN     ),
        .CLK_DPS2_EN     (CLK_DPS2_EN     ),
        .CLK_DPS3_EN     (CLK_DPS3_EN     ),
        .CLK_DPS4_EN     (CLK_DPS4_EN     ),
        .CLK_DPS5_EN     (CLK_DPS5_EN     ),
        .CLK_DPS6_EN     (CLK_DPS6_EN     ),
        .CLK_DPSF_EN     (CLK_DPSF_EN     ),
        .CLK_CAS5_EN     (CLK_CAS5_EN     ),
        .CLKOUT0_SYN_EN  (CLKOUT0_SYN_EN  ),
        .CLKOUT1_SYN_EN  (CLKOUT1_SYN_EN  ),
        .CLKOUT2_SYN_EN  (CLKOUT2_SYN_EN  ),
        .CLKOUT3_SYN_EN  (CLKOUT3_SYN_EN  ),
        .CLKOUT4_SYN_EN  (CLKOUT4_SYN_EN  ),
        .CLKOUT5_SYN_EN  (CLKOUT5_SYN_EN  ),
        .CLKOUT6_SYN_EN  (CLKOUT6_SYN_EN  ),
        .CLKOUTF_SYN_EN  (CLKOUTF_SYN_EN  ),
        .SSC_MODE        (SSC_MODE        ),
        .SSC_FREQ        (SSC_FREQ        ),
        .INTERNAL_FB     (INTERNAL_FB     ),
        .EXTERNAL_FB     (EXTERNAL_FB     ),
        .BANDWIDTH       (BANDWIDTH       )
    ) u_gpll (
        .CLKOUT0        (clkout0        ),
        .CLKOUT0N       (               ),
        .CLKOUT1        (clkout1        ),
        .CLKOUT1N       (               ),
        .CLKOUT2        (               ),
        .CLKOUT2N       (               ),
        .CLKOUT3        (               ),
        .CLKOUT3N       (               ),
        .CLKOUT4        (               ),
        .CLKOUT5        (               ),
        .CLKOUT6        (               ),
        .CLKOUTF        (               ),
        .CLKOUTFN       (               ),
        .LOCK           (pll_lock       ),
        .DPS_DONE       (               ),
        .DPS_CLK        (dps_clk        ),
        .DPS_EN         (dps_en         ),
        .DPS_DIR        (dps_dir        ),
        .CLKIN1         (clkin1         ),
        .CLKIN2         (clkin2         ),
        .CLKFB          (clkfb          ),
        .CLKIN_SEL      (clkin_sel      ),
        .CLKOUT0_SYN    (clkout0_syn    ),
        .CLKOUT1_SYN    (clkout1_syn    ),
        .CLKOUT2_SYN    (clkout2_syn    ),
        .CLKOUT3_SYN    (clkout3_syn    ),
        .CLKOUT4_SYN    (clkout4_syn    ),
        .CLKOUT5_SYN    (clkout5_syn    ),
        .CLKOUT6_SYN    (clkout6_syn    ),
        .CLKOUTF_SYN    (clkoutf_syn    ),
        .PLL_PWD        (pll_pwd        ),
        .RST            (rst            ),
        .APB_RDATA      (               ),
        .APB_READY      (               ),
        .APB_CLK        (apb_clk        ),
        .APB_RST_N      (apb_rst_n      ),
        .APB_ADDR       (apb_addr       ),
        .APB_SEL        (apb_sel        ),
        .APB_EN         (apb_en         ),
        .APB_WRITE      (apb_write      ),
        .APB_WDATA      (apb_wdata      )
    );

endmodule
