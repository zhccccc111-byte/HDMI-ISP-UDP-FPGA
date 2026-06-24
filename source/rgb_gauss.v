module rgb_gauss #(
    parameter ROW       =   1080             ,
    parameter COL       =   1920
) (
    input                   clk             ,
    input                   rst_n           ,
    
    input                   pre_vsync       ,
    input                   pre_hsync       ,
    input                   pre_href        ,
    input [7:0]             pre_r           ,
    input [7:0]             pre_g           ,
    input [7:0]             pre_b           ,

    output                  post_vsync      ,
    output                  post_hsync      ,
    output                  post_href       ,
    output [7:0]            post_r          ,
    output [7:0]            post_g          ,
    output [7:0]            post_b      
);
    reg [5:0]               vsync_r         ;
    reg [5:0]               hsync_r         ;

    reg pre_vsync_r;
    reg pre_hsync_r;
    reg pre_href_r;

    reg [7:0] pre_r_r;
    reg [7:0] pre_g_r;
    reg [7:0] pre_b_r;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pre_vsync_r <= 1'd0;
            pre_hsync_r <= 1'd0;
            pre_href_r <= 1'd0;
            pre_r_r <= 8'd0;
            pre_g_r <= 8'd0;
            pre_b_r <= 8'd0;
       end else begin
            pre_vsync_r <= pre_vsync;
            pre_hsync_r <= pre_hsync;
            pre_href_r <= pre_href;
            pre_r_r <= pre_r;
            pre_g_r <= pre_g;
            pre_b_r <= pre_b; 
      end
    end


    gauss_filter #(
        .COL                (COL        )   ,
        .ROW                (ROW        )   
    ) 
    r_filter (
        .clk                (clk        )   ,
        .rst_n              (rst_n      )   ,
        .y_de               (pre_href_r   )   ,
        .y_data             (pre_r_r     )   ,
        .gauss_de           (post_href  )   ,
        .gauss_data         (post_r     )
    );

    gauss_filter #(
        .COL                (COL        )   ,
        .ROW                (ROW        )   
    ) 
    g_filter (
        .clk                (clk        )   ,
        .rst_n              (rst_n      )   ,
        .y_de               (pre_href_r   )   ,
        .y_data             (pre_g_r      )   ,
        .gauss_de           (           )   ,
        .gauss_data         (post_g     )
    );

    gauss_filter #(
        .COL                (COL        )   ,
        .ROW                (ROW        )   
    ) 
    b_filter (
        .clk                (clk        )   ,
        .rst_n              (rst_n      )   ,
        .y_de               (pre_href_r   )   ,
        .y_data             (pre_b_r      )   ,
        .gauss_de           (           )   ,
        .gauss_data         (post_b     )
    );

    // ???????????
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            vsync_r <= 6'd0;
        else
            vsync_r <= {vsync_r[4:0], pre_vsync_r}; 
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            hsync_r <= 6'd0;
        else
            hsync_r <= {hsync_r[4:0], pre_hsync_r};
    end

    assign post_vsync = vsync_r[5];
    assign post_hsync = hsync_r[5];

endmodule