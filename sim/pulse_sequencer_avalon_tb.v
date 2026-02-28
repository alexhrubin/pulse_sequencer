`timescale 1ns/1ps

// pulse_sequencer_avalon_tb.v
//
// Testbench for the extended NV center pulse sequencer.
// Tests: BRAM write/readback, single-step super-cycle (legacy behaviour),
// multi-step super-cycle, multi-slot pulses, markers, MW output,
// configurable sync, finite super-cycle count, stop, idle outputs.

module pulse_sequencer_avalon_tb;

// ---------------------------------------------------------------------------
// DUT parameters (small values to keep simulation fast)
// ---------------------------------------------------------------------------
localparam MAX_CYCLE_TYPES = 8;
localparam MAX_SLOTS       = 16;
localparam MAX_SEQ_LEN     = 32;
localparam NUM_MARKERS     = 3;
localparam WORDS_PER_CYCLE = 1 + MAX_SLOTS*6 + 2 + NUM_MARKERS*2; // 105

// BRAM offsets (must match RTL)
localparam OFF_SEQ_LIMIT = 0;
localparam OFF_RP        = 1;
localparam OFF_RO        = 1 + MAX_SLOTS*2;
localparam OFF_MW        = 1 + MAX_SLOTS*4;
localparam OFF_SYNC_ST   = 1 + MAX_SLOTS*6;
localparam OFF_SYNC_DUR  = 2 + MAX_SLOTS*6;
localparam OFF_MK_BASE   = 3 + MAX_SLOTS*6;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg        clk;
reg        reset_n;
reg  [6:0] avs_address;
reg        avs_write;
reg        avs_read;
reg [31:0] avs_writedata;
wire [31:0] avs_readdata;
wire        aom_rp_out, aom_ro_out, mw_out, sync_out;
wire [NUM_MARKERS-1:0] marker_out;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
pulse_sequencer_avalon #(
    .MAX_CYCLE_TYPES (MAX_CYCLE_TYPES),
    .MAX_SLOTS       (MAX_SLOTS),
    .MAX_SEQ_LEN     (MAX_SEQ_LEN),
    .NUM_MARKERS     (NUM_MARKERS)
) uut (
    .clk              (clk),
    .reset_n          (reset_n),
    .avs_s0_address   (avs_address),
    .avs_s0_write     (avs_write),
    .avs_s0_writedata (avs_writedata),
    .avs_s0_read      (avs_read),
    .avs_s0_readdata  (avs_readdata),
    .aom_rp_out       (aom_rp_out),
    .aom_ro_out       (aom_ro_out),
    .mw_out           (mw_out),
    .sync_out         (sync_out),
    .marker_out       (marker_out)
);

// ---------------------------------------------------------------------------
// 50 MHz clock
// ---------------------------------------------------------------------------
initial clk = 0;
always #10 clk = ~clk;

// ---------------------------------------------------------------------------
// Bus tasks
// ---------------------------------------------------------------------------
task write_reg;
    input [6:0]  addr;
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

task read_reg;
    input [6:0] addr;
    begin
        @(negedge clk);
        avs_address = addr;
        avs_read    = 1;
        @(posedge clk);
        @(negedge clk);
        avs_read    = 0;
    end
endtask

// Write a word to BRAM via the indirect-access port.
// Caller must set BRAM_ADDR first; subsequent calls auto-increment.
task bram_write;
    input [31:0] data;
    begin
        write_reg(7'h07, data);
    end
endtask

// Write a complete cycle-type config block to BRAM slot 'ct_idx'.
// buf[] is WORDS_PER_CYCLE long; only [OFF_SEQ_LIMIT], [OFF_RP+0], etc. matter.
task write_cycle_type;
    input [2:0]  ct_idx;
    input [31:0] seq_lim;
    input [31:0] rp_st0;  input [31:0] rp_du0;  // slot 0 only for brevity
    input [31:0] ro_st0;  input [31:0] ro_du0;
    input [31:0] mw_st0;  input [31:0] mw_du0;
    input [31:0] sync_st; input [31:0] sync_du;
    input [31:0] mk0_st;  input [31:0] mk0_du;
    integer i;
    begin
        // Set BRAM address to start of this cycle type's block
        write_reg(7'h06, {8'd0, ct_idx, 7'd0}); // ct_idx * 128

        // +0: seq_limit
        bram_write(seq_lim);
        // +1..+32: RP slots (slot 0 configured, rest zeroed)
        bram_write(rp_st0); bram_write(rp_du0);
        for (i = 1; i < MAX_SLOTS; i = i + 1) begin
            bram_write(32'd0); bram_write(32'd0);
        end
        // +33..+64: RO slots
        bram_write(ro_st0); bram_write(ro_du0);
        for (i = 1; i < MAX_SLOTS; i = i + 1) begin
            bram_write(32'd0); bram_write(32'd0);
        end
        // +65..+96: MW slots
        bram_write(mw_st0); bram_write(mw_du0);
        for (i = 1; i < MAX_SLOTS; i = i + 1) begin
            bram_write(32'd0); bram_write(32'd0);
        end
        // +97,+98: sync
        bram_write(sync_st); bram_write(sync_du);
        // +99,+100: marker 0
        bram_write(mk0_st); bram_write(mk0_du);
        // +101..+104: markers 1,2 (disabled)
        bram_write(32'd0); bram_write(32'd0);
        bram_write(32'd0); bram_write(32'd0);
    end
endtask

// ---------------------------------------------------------------------------
// Pass/fail bookkeeping
// ---------------------------------------------------------------------------
integer fail_count;

task check;
    input [255:0] label;
    input [31:0]  got;
    input [31:0]  expected;
    begin
        if (got !== expected) begin
            $display("FAIL  %-28s  got=%0d  expected=%0d  @%0t ns",
                     label, got, expected, $time);
            fail_count = fail_count + 1;
        end else
            $display("pass  %-28s  = %0d", label, got);
    end
endtask

// Count how many clock cycles a signal is high within a window.
// Returns result in 'cnt'.
integer pulse_cnt;
task count_pulses;
    input       sig;
    input [31:0] n_cycles;
    integer j;
    begin
        pulse_cnt = 0;
        for (j = 0; j < n_cycles; j = j + 1) begin
            @(posedge clk);
            if (sig) pulse_cnt = pulse_cnt + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Main test sequence
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("sim/seq_test.vcd");
    $dumpvars(0, pulse_sequencer_avalon_tb);

    fail_count    = 0;
    avs_write     = 0;
    avs_read      = 0;
    avs_address   = 0;
    avs_writedata = 0;

    // Reset
    reset_n = 0;
    repeat (5) @(posedge clk);
    reset_n = 1;
    repeat (2) @(posedge clk);

    // ==========================================================================
    // Test 1: BRAM write and readback
    // Write a known pattern to BRAM word 0 and read it back.
    // ==========================================================================
    $display("\n[1] BRAM write/readback");
    write_reg(7'h06, 32'd0);          // BRAM addr = 0
    write_reg(7'h07, 32'hDEADBEEF);   // write; addr auto-increments to 1
    write_reg(7'h07, 32'hCAFEBABE);   // write addr 1; auto-increments to 2

    write_reg(7'h06, 32'd0);          // reset addr to 0
    read_reg(7'h07); check("BRAM[0]", avs_readdata, 32'hDEADBEEF);
    write_reg(7'h06, 32'd1);
    read_reg(7'h07); check("BRAM[1]", avs_readdata, 32'hCAFEBABE);

    // ==========================================================================
    // Test 2: Legacy single-step super-cycle
    // One cycle type (index 0), seq_len=1, count=1, repeat infinite.
    // Mimics original behaviour: RP 10..29, RO 40..54, sync 30..49 (20 cy),
    // period = 100 cycles.
    // ==========================================================================
    $display("\n[2] Legacy single-step (RP/RO/sync, period=100)");

    // Cycle type 0: seq_limit=100, RP@10+20, RO@40+15, sync@30+20
    write_cycle_type(
        3'd0,
        32'd100,                     // seq_limit
        32'd10,  32'd20,             // RP slot 0
        32'd40,  32'd15,             // RO slot 0
        32'd0,   32'd0,              // MW disabled
        32'd30,  32'd20,             // sync start, dur
        32'd0,   32'd0               // marker 0 disabled
    );

    // Sequence: one step, cycle type 0, count=1
    write_reg(7'h05, 32'd1);          // SEQ_LEN = 1
    write_reg(7'h10, 32'd0);          // SEQ_TYPE[0] = 0
    write_reg(7'h30, 32'd1);          // SEQ_COUNT[0] = 1
    write_reg(7'h01, 32'd0);          // SUPER_REPEAT_LIMIT = 0 (infinite)

    // Verify idle
    read_reg(7'h00); check("idle before start", avs_readdata[0], 1'd0);

    write_reg(7'h00, 32'd1);          // start strobe

    // Allow startup prefetch (~107 cycles) + a few extra
    repeat (120) @(posedge clk);
    read_reg(7'h00); check("running after start", avs_readdata[0], 1'd1);

    // Run 5 full periods (500 cycles) for VCD inspection
    repeat (500) @(posedge clk);

    // Verify RP is high exactly 20 cycles per 100-cycle period:
    // sample one full period
    begin : rp_check
        integer rp_hi, ro_hi, sync_lo;
        integer k;
        rp_hi   = 0;
        ro_hi   = 0;
        sync_lo = 0;
        for (k = 0; k < 100; k = k + 1) begin
            @(posedge clk);
            if (aom_rp_out) rp_hi   = rp_hi   + 1;
            if (aom_ro_out) ro_hi   = ro_hi   + 1;
            if (!sync_out)  sync_lo = sync_lo + 1;
        end
        check("RP high cycles/period",   rp_hi,   32'd20);
        check("RO high cycles/period",   ro_hi,   32'd15);
        check("sync low cycles/period",  sync_lo, 32'd20);
    end

    // Stop
    write_reg(7'h00, 32'd2);
    repeat (3) @(posedge clk);
    read_reg(7'h00); check("stopped after stop", avs_readdata[0], 1'd0);
    @(negedge clk);
    check("RP idle after stop",   {31'd0, aom_rp_out}, 32'd0);
    check("RO idle after stop",   {31'd0, aom_ro_out}, 32'd0);
    check("MW idle after stop",   {31'd0, mw_out},     32'd0);
    check("sync idle after stop", {31'd0, sync_out},   32'd1);

    // ==========================================================================
    // Test 3: Multi-step super-cycle  (2 steps: cal + experiment)
    // Cycle type 0: cal_ms0 — RP only, period=200, marker0 at start
    // Cycle type 1: experiment — RO + MW + sync, period=300
    // Sequence: [ct0 x1, ct1 x1], infinite super-cycles.
    // Verify that each output is only high in its designated cycle type.
    // ==========================================================================
    $display("\n[3] Multi-step super-cycle (cal + experiment)");

    // Cycle type 0: cal — RP@10+50, period=200, marker0@0+5
    write_cycle_type(
        3'd0,
        32'd200,                     // seq_limit
        32'd10,  32'd50,             // RP slot 0
        32'd0,   32'd0,              // RO disabled
        32'd0,   32'd0,              // MW disabled
        32'd0,   32'd0,              // sync disabled
        32'd0,   32'd5               // marker0 @0 dur=5
    );

    // Cycle type 1: experiment — RO@20+80, MW@30+40, sync@0+10, no RP
    write_cycle_type(
        3'd1,
        32'd300,                     // seq_limit
        32'd0,   32'd0,              // RP disabled
        32'd20,  32'd80,             // RO slot 0
        32'd30,  32'd40,             // MW slot 0
        32'd0,   32'd10,             // sync @0 dur=10
        32'd0,   32'd0               // marker0 disabled
    );

    write_reg(7'h05, 32'd2);          // SEQ_LEN = 2
    write_reg(7'h10, 32'd0);          // SEQ_TYPE[0] = ct0 (cal)
    write_reg(7'h30, 32'd1);          // SEQ_COUNT[0] = 1
    write_reg(7'h11, 32'd1);          // SEQ_TYPE[1] = ct1 (experiment)
    write_reg(7'h31, 32'd1);          // SEQ_COUNT[1] = 1
    write_reg(7'h01, 32'd0);          // infinite super-cycles

    write_reg(7'h00, 32'd1);          // start

    // Wait for startup prefetch
    repeat (120) @(posedge clk);
    read_reg(7'h00); check("running 2-step", avs_readdata[0], 1'd1);

    // Count one complete super-cycle (200 cal + 300 expt = 500 cycles).
    // Summing over exactly one period is phase-independent: starting anywhere
    // within the super-cycle, any 500-cycle window captures the full pulse
    // content of one cal and one expt period.
    // Expected totals:  RP=50 (cal only), RO=80 (expt only), MW=40 (expt only),
    //                   mk0=5 (cal only), sync_lo=10 (expt only).
    begin : supercycle_check
        integer rp_hi, ro_hi, mw_hi, mk0_hi, sync_lo;
        integer k;
        rp_hi   = 0; ro_hi  = 0; mw_hi = 0; mk0_hi = 0; sync_lo = 0;
        for (k = 0; k < 500; k = k + 1) begin
            @(posedge clk);
            if (aom_rp_out)    rp_hi   = rp_hi   + 1;
            if (aom_ro_out)    ro_hi   = ro_hi   + 1;
            if (mw_out)        mw_hi   = mw_hi   + 1;
            if (marker_out[0]) mk0_hi  = mk0_hi  + 1;
            if (!sync_out)     sync_lo = sync_lo + 1;
        end
        check("sc: RP high total",  rp_hi,   32'd50);
        check("sc: RO high total",  ro_hi,   32'd80);
        check("sc: MW high total",  mw_hi,   32'd40);
        check("sc: mk0 high total", mk0_hi,  32'd5);
        check("sc: sync low total", sync_lo, 32'd10);
    end

    write_reg(7'h00, 32'd2); // stop

    // ==========================================================================
    // Test 4: Multi-slot RP — two non-overlapping RP pulses per cycle
    // ==========================================================================
    $display("\n[4] Multi-slot RP (2 pulses per cycle)");
    repeat (3) @(posedge clk);

    // Write cycle type 0 with two RP slots manually
    write_reg(7'h06, 32'd0);          // BRAM addr = start of ct0

    // +0: seq_limit = 400
    bram_write(32'd400);
    // +1,+2: RP slot 0 — start=10, dur=30
    bram_write(32'd10); bram_write(32'd30);
    // +3,+4: RP slot 1 — start=200, dur=50
    bram_write(32'd200); bram_write(32'd50);
    // zero remaining RP slots (+5..+32)
    begin : zero_rp
        integer i;
        for (i = 2; i < MAX_SLOTS; i = i + 1) begin
            bram_write(32'd0); bram_write(32'd0);
        end
    end
    // RO, MW all disabled (zeros)
    begin : zero_ro_mw
        integer i;
        for (i = 0; i < MAX_SLOTS*2; i = i + 1) bram_write(32'd0);
        for (i = 0; i < MAX_SLOTS*2; i = i + 1) bram_write(32'd0);
    end
    // sync disabled
    bram_write(32'd0); bram_write(32'd0);
    // markers disabled
    bram_write(32'd0); bram_write(32'd0);
    bram_write(32'd0); bram_write(32'd0);
    bram_write(32'd0); bram_write(32'd0);

    write_reg(7'h05, 32'd1);
    write_reg(7'h10, 32'd0);
    write_reg(7'h30, 32'd1);
    write_reg(7'h01, 32'd0);
    write_reg(7'h00, 32'd1);           // start

    repeat (120) @(posedge clk);       // wait for startup prefetch

    begin : multi_rp_check
        integer rp_hi;
        integer k;
        rp_hi = 0;
        for (k = 0; k < 400; k = k + 1) begin
            @(posedge clk);
            if (aom_rp_out) rp_hi = rp_hi + 1;
        end
        // Expect 30 + 50 = 80 high cycles per 400-cycle period
        check("multi-slot RP high/period", rp_hi, 32'd80);
    end

    write_reg(7'h00, 32'd2); // stop

    // ==========================================================================
    // Test 5: Finite super-cycle count (super_repeat_limit = 2)
    // 2-step sequence, total period = 200+300 = 500 cycles.
    // After 2 super-cycles (1000 cycles) sequencer should halt.
    // ==========================================================================
    $display("\n[5] Finite super-cycle count (limit=2)");
    repeat (3) @(posedge clk);

    // Re-write ct0 and ct1 (test 4 overwrote ct0 with the multi-slot config).
    write_cycle_type(
        3'd0, 32'd200,
        32'd10, 32'd50,  32'd0,  32'd0,   32'd0, 32'd0,
        32'd0,  32'd0,   32'd0,  32'd5
    );
    write_cycle_type(
        3'd1, 32'd300,
        32'd0,  32'd0,   32'd20, 32'd80,  32'd30, 32'd40,
        32'd0,  32'd10,  32'd0,  32'd0
    );

    write_reg(7'h05, 32'd2);
    write_reg(7'h10, 32'd0); write_reg(7'h30, 32'd1);
    write_reg(7'h11, 32'd1); write_reg(7'h31, 32'd1);
    write_reg(7'h01, 32'd2); // SUPER_REPEAT_LIMIT = 2

    write_reg(7'h00, 32'd1); // start

    // Wait for startup + 2 full super-cycles + margin
    // Each super-cycle = 500 cycles; plus ~120 startup = ~1120 total; use 1300.
    repeat (1300) @(posedge clk);

    read_reg(7'h00); check("finite: running stopped", avs_readdata[0], 1'd0);
    read_reg(7'h02); check("finite: super_count=2",   avs_readdata,    32'd2);

    // ==========================================================================
    // Test 6: Repeat count > 1 within a step (SEQ_COUNT=3 for cal cycle)
    // ==========================================================================
    $display("\n[6] SEQ_COUNT=3 within a step");
    repeat (3) @(posedge clk);

    // Re-write ct0 and ct1 to known state (test 4 had overwritten ct0).
    write_cycle_type(
        3'd0, 32'd200,
        32'd10, 32'd50,  32'd0,  32'd0,   32'd0, 32'd0,
        32'd0,  32'd0,   32'd0,  32'd5
    );
    write_cycle_type(
        3'd1, 32'd300,
        32'd0,  32'd0,   32'd20, 32'd80,  32'd30, 32'd40,
        32'd0,  32'd10,  32'd0,  32'd0
    );

    write_reg(7'h05, 32'd2);
    write_reg(7'h10, 32'd0); write_reg(7'h30, 32'd3); // cal x3
    write_reg(7'h11, 32'd1); write_reg(7'h31, 32'd1); // expt x1
    write_reg(7'h01, 32'd1); // one super-cycle then stop

    write_reg(7'h00, 32'd1);

    // One super-cycle = 3*200 + 1*300 = 900 cycles; add startup + margin = 1200
    repeat (1200) @(posedge clk);

    read_reg(7'h00); check("count=3: stopped",      avs_readdata[0], 1'd0);
    read_reg(7'h02); check("count=3: super_count=1", avs_readdata,   32'd1);

    // ==========================================================================
    // Summary
    // ==========================================================================
    repeat (5) @(posedge clk);
    $display("\n--- Simulation complete: %0d failure(s) ---\n", fail_count);
    if (fail_count == 0)
        $display("ALL TESTS PASSED");
    else
        $display("SOME TESTS FAILED");

    #100;
    $finish;
end

endmodule
