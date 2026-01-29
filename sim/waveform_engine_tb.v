`timescale 1ns / 1ps

module waveform_engine_tb;

    // 1. Declare signals to connect to the module
    // "reg" for things WE control (inputs to the chip)
    // "wire" for things the CHIP controls (outputs)
    reg clk;
    reg reset_n;
    reg load_we;
    reg [9:0] load_addr;
    reg [13:0] load_data;
    reg ctrl_run;
    reg [31:0] cfg_divider;
    
    wire [13:0] dac_out;

    // 2. Instantiate the Unit Under Test (UUT)
    waveform_engine #(
        .ADDR_WIDTH(10),
        .DATA_WIDTH(14)
    ) uut (
        .clk(clk),
        .reset_n(reset_n),
        .load_we(load_we),
        .load_addr(load_addr),
        .load_data(load_data),
        .ctrl_run(ctrl_run),
        .cfg_divider(cfg_divider),
        .dac_out(dac_out)
    );

    // 3. Clock Generation (The Heartbeat)
    // Toggle clock every 10ns -> 20ns period = 50MHz
    initial clk = 0;
    always #10 clk = ~clk;

    integer i;

    // 4. The Test Procedure
    initial begin
        // Setup for Waveform Viewer (GTKWave)
        $dumpfile("waveform.vcd");
        $dumpvars(0, waveform_engine_tb);

        // --- Zero out all memory ---
        $display("Clearing Memory...");
        reset_n = 0;
        clk = 0;
        load_we = 1;
        load_data = 0;
        
        // Loop through all 1024 addresses and write '0'
        for (i = 0; i < 1024; i = i + 1) begin
            load_addr = i;
            @(negedge clk);
        end
        
        load_we = 0;

        // --- STEP A: Initialize ---
        $display("Initializing...");
        reset_n = 0;      // Hold reset
        load_we = 0;
        ctrl_run = 0;
        cfg_divider = 5;  // Run at 1/5th speed (simulates slow sample rate)
        #100;
        reset_n = 1;      // Release reset
        #20;

        // --- STEP B: Load "Fake" Waveform (Simulate Python) ---
        $display("Loading RAM...");
        
        // Sample 0: Value 100
        load_addr = 0; load_data = 14'd100; load_we = 1; #20; 
        
        // Sample 1: Value 500
        load_addr = 1; load_data = 14'd500; load_we = 1; #20;
        
        // Sample 2: Value 1000
        load_addr = 2; load_data = 14'd1000; load_we = 1; #20;
        
        // Sample 3: Value 0
        load_addr = 3; load_data = 14'd0;    load_we = 1; #20;
        load_addr = 4; load_data = 14'd77;    load_we = 1; #20;

        load_we = 0; // Stop writing
        #50;

        // --- STEP C: Start Playback ---
        $display("Starting Playback...");
        ctrl_run = 1;

        // Let it run for 500ns to see the counter wrap a few times
        #2000;

        // --- STEP D: Finish ---
        $display("Test Complete.");
        $finish;
    end

endmodule
