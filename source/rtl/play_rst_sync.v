`timescale 1ns / 1ps

module play_rst_sync (
    input  clk,
    input  rst_n,
    input  sig_async,
    output sig_synced
);

reg sync_d0;
reg sync_d1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sync_d0 <= 1'b0;
        sync_d1 <= 1'b0;
    end else begin
        sync_d0 <= sig_async;
        sync_d1 <= sync_d0;
    end
end

assign sig_synced = sync_d1;

endmodule
