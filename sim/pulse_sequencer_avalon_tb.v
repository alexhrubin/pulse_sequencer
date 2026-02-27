`timescale 1ns/1ps

module pulse_sequencer_avalon_tb;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg         clk;
    reg         reset_n;
    reg  [4:0]  avs_address;
    reg         avs_write;
    reg         avs_read;
    reg  [31:0] avs_writedata;
    wire [31:0] avs_readdata;
    wire        aom_rp_out, aom_ro_out, sync_out;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    pulse_sequencer_avalon uut (
        .clk              (clk),
        .reset_n          (reset_n),
        .avs_s0_address   (avs_address),
        .avs_s0_write     (avs_write),
        .avs_s0_writedata (avs_writedata),
        .avs_s0_read      (avs_read),
        .avs_s0_readdata  (avs_readdata),
        .aom_rp_out       (aom_rp_out),
        .aom_ro_out       (aom_ro_out),
        .sync_out         (sync_out)
    );

    // -------------------------------------------------------------------------
    // 50 MHz clock
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #10 clk = ~clk;  // 20 ns period

    // -------------------------------------------------------------------------
    // Tasks
    //
    // Stimulus is driven on negedge so it meets setup time at the next posedge.
    // -------------------------------------------------------------------------

    // Write a register. Data is presented for exactly one clock cycle.
    task write_reg;
        input [4:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            avs_address   = addr;
            avs_writedata = data;
            avs_write     = 1;
            @(negedge clk);
            avs_write     = 0;
        end
    endtask

    // Read a register (latency = 1).  After the task returns, avs_readdata
    // holds the result and is stable until the next bus transaction.
    task read_reg;
        input [4:0] addr;
        begin
            @(negedge clk);
            avs_address = addr;
            avs_read    = 1;
            @(posedge clk);   // data is registered on this rising edge
            @(negedge clk);   // wait for output to settle, then deassert
            avs_read    = 0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Pass/fail bookkeeping
    // -------------------------------------------------------------------------
    integer fail_count;

    task check;
        input [255:0] label;      // test name (up to 32 chars)
        input [31:0]  got;
        input [31:0]  expected;
        begin
            if (got !== expected) begin
                $display("FAIL  %-20s  got=%0d  expected=%0d  @%0t ns",
                         label, got, expected, $time);
                fail_count = fail_count + 1;
            end else begin
                $display("pass  %-20s  = %0d", label, got);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("sim/seq_test.vcd");
        $dumpvars(0, pulse_sequencer_avalon_tb);

        fail_count    = 0;
        avs_write     = 0;
        avs_read      = 0;
        avs_address   = 0;
        avs_writedata = 0;

        // --- Reset ---
        reset_n = 0;
        repeat (5) @(posedge clk);
        reset_n = 1;
        repeat (2) @(posedge clk);

        // =====================================================================
        // 1. Write all parameters
        // =====================================================================
        $display("\n[1] Writing parameters");
        write_reg(5'h01, 32'd100);  // seq_limit  = 100 cycles (2 us @ 50 MHz)
        write_reg(5'h02, 32'd10);   // rp_start   = 10
        write_reg(5'h03, 32'd20);   // rp_dur     = 20  -> RP active 10..29
        write_reg(5'h04, 32'd40);   // ro_start   = 40
        write_reg(5'h05, 32'd15);   // ro_dur     = 15  -> RO active 40..54
        write_reg(5'h06, 32'd30);   // sync_start = 30  -> SYNC low 30..49 (fixed 20 cycles)
        write_reg(5'h07, 32'd0);    // repeat_limit = 0 (infinite)

        // =====================================================================
        // 2. Read back all parameters
        // =====================================================================
        $display("\n[2] Readback verification");
        read_reg(5'h01); check("seq_limit",    avs_readdata, 32'd100);
        read_reg(5'h02); check("rp_start",     avs_readdata, 32'd10);
        read_reg(5'h03); check("rp_dur",       avs_readdata, 32'd20);
        read_reg(5'h04); check("ro_start",     avs_readdata, 32'd40);
        read_reg(5'h05); check("ro_dur",       avs_readdata, 32'd15);
        read_reg(5'h06); check("sync_start",   avs_readdata, 32'd30);
        read_reg(5'h07); check("repeat_limit", avs_readdata, 32'd0);

        // =====================================================================
        // 3. Verify idle status
        // =====================================================================
        $display("\n[3] Status register (idle)");
        read_reg(5'h00); check("running (idle)",  avs_readdata[0], 1'b0);

        // =====================================================================
        // 4. Start (infinite loop) and verify running
        // =====================================================================
        $display("\n[4] Start sequencer (infinite)");
        write_reg(5'h00, 32'd1);    // bit 0 = start
        // start_trigger is a one-cycle strobe; engine sees it on the cycle after
        // the write register, so allow 3 cycles for the running flag to appear.
        repeat (3) @(posedge clk);
        read_reg(5'h00); check("running (active)", avs_readdata[0], 1'b1);

        // =====================================================================
        // 5. Let it run for ~5 full periods (5 * 100 cycles = 500 clocks)
        //    and visually inspect the VCD for correct pulse shapes.
        // =====================================================================
        $display("\n[5] Running for 5 periods...");
        repeat (500) @(posedge clk);

        // =====================================================================
        // 6. Stop (immediate halt)
        // =====================================================================
        $display("\n[6] Stop sequencer");
        write_reg(5'h00, 32'd2);    // bit 1 = stop
        repeat (3) @(posedge clk);
        read_reg(5'h00); check("running (stopped)", avs_readdata[0], 1'b0);

        // Verify all outputs are in their idle states after stop
        @(negedge clk);
        if (aom_rp_out !== 1'b0) begin
            $display("FAIL  aom_rp_out after stop  = %b  expected 0", aom_rp_out);
            fail_count = fail_count + 1;
        end else
            $display("pass  aom_rp_out after stop  = 0");

        if (aom_ro_out !== 1'b0) begin
            $display("FAIL  aom_ro_out after stop  = %b  expected 0", aom_ro_out);
            fail_count = fail_count + 1;
        end else
            $display("pass  aom_ro_out after stop  = 0");

        if (sync_out !== 1'b1) begin
            $display("FAIL  sync_out after stop    = %b  expected 1 (active-low idle)", sync_out);
            fail_count = fail_count + 1;
        end else
            $display("pass  sync_out after stop    = 1 (idle)");

        // =====================================================================
        // 7. Finite repetition: repeat_limit = 3
        //    Expected: 3 periods execute, then sequencer halts on its own.
        //    repeat_count after completion = 2
        //      (increments on each period boundary; starts at 0, so
        //       0->1 after period 1, 1->2 after period 2, then stops at period 3)
        // =====================================================================
        $display("\n[7] Finite repetitions (3x)");
        write_reg(5'h07, 32'd3);    // repeat_limit = 3
        write_reg(5'h00, 32'd1);    // start

        // Wait well past 3 periods (3 * 100 + margin = 350 cycles)
        repeat (350) @(posedge clk);

        read_reg(5'h00); check("running (finished)",  avs_readdata[0], 1'b0);
        read_reg(5'h08); check("repeat_count",        avs_readdata,    32'd2);

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n--- Simulation complete: %0d failure(s) ---\n", fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        #100;
        $finish;
    end

endmodule
