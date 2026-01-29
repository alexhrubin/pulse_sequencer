`timescale 1ns / 1ps

module avalon_waveform_wrapper_tb;

    // --- Signals ---
    reg clk;
    reg reset_n;

    // Avalon-MM Slave Interface Signals
    reg  [10:0] avs_address;
    reg         avs_write;
    reg  [31:0] avs_writedata;
    reg         avs_read;
    wire [31:0] avs_readdata;

    // Exported Conduit
    wire [13:0] dac_out;

    // --- UUT: Avalon Wrapper ---
    avalon_waveform_wrapper uut (
        .clk(clk),
        .reset_n(reset_n),
        .avs_address(avs_address),
        .avs_write(avs_write),
        .avs_writedata(avs_writedata),
        .avs_read(avs_read),
        .avs_readdata(avs_readdata),
        .conduit_dac_out(dac_out)
    );

    // --- Clock Generation (50MHz) ---
    initial clk = 0;
    always #10 clk = ~clk;

    // --- Avalon Write Task ---
    // This encapsulates the Avalon-MM write protocol: 
    // Address and Data must be stable while Write is asserted.
    task avalon_write;
        input [10:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            avs_address   = addr;
            avs_writedata = data;
            avs_write     = 1;
            @(negedge clk);
            avs_write     = 0;
            avs_address   = 0;
            avs_writedata = 0;
        end
    endtask

    // --- Stimulus ---
    initial begin
        $dumpfile("wrapper_sim.vcd");
        $dumpvars(0, avalon_waveform_wrapper_tb);

        // Initialization
        reset_n = 0;
        avs_write = 0;
        avs_read = 0;
        #100;
        reset_n = 1;
        #20;

        // 1. Configure Engine via Register Map
        // Address 1025 = Divider
        avalon_write(11'd1025, 32'd2); 
        
        // 2. Load Waveform Data via Memory Map
        // Address 0-2 = RAM
        avalon_write(11'd0, 32'd4096); 
        avalon_write(11'd1, 32'd8192);
        avalon_write(11'd2, 32'd16383);
        
        // 3. Enable Engine
        // Address 1024 = Control (Bit 0 is Run)
        avalon_write(11'd1024, 32'd1);

        #1000;
        $finish;
    end

endmodule