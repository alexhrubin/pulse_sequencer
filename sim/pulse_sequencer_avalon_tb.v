`timescale 1ns/1ps

// pulse_sequencer_avalon_tb.v
//
// Testbench for the extended NV center pulse sequencer.
// Tests: BRAM write/readback, single-step super-cycle (legacy behaviour),
// multi-step super-cycle, multi-slot pulses, veto output,
// finite super-cycle count, stop, idle outputs, SEQ_COUNT>1.

module pulse_sequencer_avalon_tb;

// ---------------------------------------------------------------------------
// DUT parameters (small values to keep simulation fast)
// ---------------------------------------------------------------------------
localparam MAX_CYCLE_TYPES = 8;
localparam MAX_SLOTS       = 16;
localparam MAX_SEQ_LEN     = 32;
localparam NUM_MARKERS     = 3;
localparam WORDS_PER_CYCLE = 1 + MAX_SLOTS*8 + 2 + NUM_MARKERS*2; // 137

// BRAM offsets (must match RTL)
localparam OFF_SEQ_LIMIT = 0;
localparam OFF_RP        = 1;
localparam OFF_RO        = 1 + MAX_SLOTS*2;
localparam OFF_MW        = 1 + MAX_SLOTS*4;
localparam OFF_VETO      = 1 + MAX_SLOTS*6;
localparam OFF_SYNC_ST   = 1 + MAX_SLOTS*8;
localparam OFF_SYNC_DUR  = 2 + MAX_SLOTS*8;
localparam OFF_MK_BASE   = 3 + MAX_SLOTS*8;

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
wire        aom_rp_out, aom_ro_out, mw_out, veto_out, sync_out;
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
    .veto_out         (veto_out),
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
// Configures slot 0 of each channel; all other slots are zeroed (disabled).
task write_cycle_type;
    input [2:0]  ct_idx;
    input [31:0] seq_lim;
    input [31:0] rp_st0;   input [31:0] rp_du0;
    input [31:0] ro_st0;   input [31:0] ro_du0;
    input [31:0] mw_st0;   input [31:0] mw_du0;
    input [31:0] veto_st0; input [31:0] veto_du0;
    input [31:0] sync_st;  input [31:0] sync_du;
    input [31:0] mk0_st;   input [31:0] mk0_du;
    integer i;
    begin
        // Set BRAM address to start of this cycle type's block (ct_idx * 256)
        write_reg(7'h06, {5'd0, ct_idx, 8'd0});

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
        // +97..+128: veto slots
        bram_write(veto_st0); bram_write(veto_du0);
        for (i = 1; i < MAX_SLOTS; i = i + 1) begin
            bram_write(32'd0); bram_write(32'd0);
        end
        // +129,+130: sync
        bram_write(sync_st); bram_write(sync_du);
        // +131,+132: marker 0
        bram_write(mk0_st); bram_write(mk0_du);
        // +133..+136: markers 1,2 (disabled)
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
    // RP@10+20, RO@40+15, sync@30+20, period=100.
    // ==========================================================================
    // seq_limit=200 ensures stall-free operation (200 > WORDS_PER_CYCLE+3 = 140).
    $display("\n[2] Legacy single-step (RP/RO/sync, period=200)");

    write_cycle_type(
        3'd0,
        32'd200,                         // seq_limit (must be >= 140 for no stall)
        32'd10,  32'd20,                 // RP slot 0
        32'd40,  32'd15,                 // RO slot 0
        32'd0,   32'd0,                  // MW disabled
        32'd0,   32'd0,                  // veto disabled
        32'd30,  32'd20,                 // sync start, dur
        32'd0,   32'd0                   // marker 0 disabled
    );

    write_reg(7'h05, 32'd1);          // SEQ_LEN = 1
    write_reg(7'h10, 32'd0);          // SEQ_TYPE[0] = 0
    write_reg(7'h30, 32'd1);          // SEQ_COUNT[0] = 1
    write_reg(7'h01, 32'd0);          // SUPER_REPEAT_LIMIT = 0 (infinite)

    read_reg(7'h00); check("idle before start", avs_readdata[0], 1'd0);

    write_reg(7'h00, 32'd1);          // start strobe

    repeat (160) @(posedge clk);      // wait for startup prefetch (140 cycles)
    read_reg(7'h00); check("running after start", avs_readdata[0], 1'd1);

    repeat (600) @(posedge clk);      // run 3 full periods for VCD inspection

    // Sample one complete period (200 cycles) — phase-independent sum
    begin : rp_check
        integer rp_hi, ro_hi, sync_lo;
        integer k;
        rp_hi   = 0;
        ro_hi   = 0;
        sync_lo = 0;
        for (k = 0; k < 200; k = k + 1) begin
            @(posedge clk);
            if (aom_rp_out) rp_hi   = rp_hi   + 1;
            if (aom_ro_out) ro_hi   = ro_hi   + 1;
            if (!sync_out)  sync_lo = sync_lo + 1;
        end
        check("RP high cycles/period",   rp_hi,   32'd20);
        check("RO high cycles/period",   ro_hi,   32'd15);
        check("sync low cycles/period",  sync_lo, 32'd20);
    end

    // Stop and verify idle state
    write_reg(7'h00, 32'd2);
    repeat (3) @(posedge clk);
    read_reg(7'h00); check("stopped after stop", avs_readdata[0], 1'd0);
    @(negedge clk);
    check("RP idle after stop",   {31'd0, aom_rp_out}, 32'd0);
    check("RO idle after stop",   {31'd0, aom_ro_out}, 32'd0);
    check("MW idle after stop",   {31'd0, mw_out},     32'd0);
    check("veto idle after stop", {31'd0, veto_out},   32'd0);
    check("sync idle after stop", {31'd0, sync_out},   32'd1);

    // ==========================================================================
    // Test 3: Multi-step super-cycle (2 steps: cal + experiment)
    // ct0: cal — RP only, period=200, marker0 at start
    // ct1: experiment — RO + MW + sync, period=300
    // Verify channel isolation by counting one full super-cycle period (500
    // cycles): phase-independent, captures exactly one cal + one expt period.
    // ==========================================================================
    $display("\n[3] Multi-step super-cycle (cal + experiment)");

    // ct0: cal — RP@10+50, marker0@0+5
    write_cycle_type(
        3'd0,
        32'd200,
        32'd10,  32'd50,                 // RP slot 0
        32'd0,   32'd0,                  // RO disabled
        32'd0,   32'd0,                  // MW disabled
        32'd0,   32'd0,                  // veto disabled
        32'd0,   32'd0,                  // sync disabled
        32'd0,   32'd5                   // marker0 @0 dur=5
    );

    // ct1: experiment — RO@20+80, MW@30+40, sync@0+10
    write_cycle_type(
        3'd1,
        32'd300,
        32'd0,   32'd0,                  // RP disabled
        32'd20,  32'd80,                 // RO slot 0
        32'd30,  32'd40,                 // MW slot 0
        32'd0,   32'd0,                  // veto disabled
        32'd0,   32'd10,                 // sync @0 dur=10
        32'd0,   32'd0                   // marker0 disabled
    );

    write_reg(7'h05, 32'd2);
    write_reg(7'h10, 32'd0); write_reg(7'h30, 32'd1); // SEQ_TYPE[0]=ct0, count=1
    write_reg(7'h11, 32'd1); write_reg(7'h31, 32'd1); // SEQ_TYPE[1]=ct1, count=1
    write_reg(7'h01, 32'd0);                           // infinite super-cycles

    write_reg(7'h00, 32'd1);             // start

    repeat (160) @(posedge clk);
    read_reg(7'h00); check("running 2-step", avs_readdata[0], 1'd1);

    // Count one complete super-cycle (500 cycles). Summing over exactly one
    // period is phase-independent — any 500-cycle window captures one cal +
    // one expt worth of pulses regardless of where we start.
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

    // Write cycle type 0 manually: seq_limit=400, RP slots 0 and 1, all else 0.
    write_reg(7'h06, 32'd0);           // BRAM addr = start of ct0 (addr 0)

    bram_write(32'd400);               // +0: seq_limit
    bram_write(32'd10);  bram_write(32'd30);  // +1,+2: RP slot 0
    bram_write(32'd200); bram_write(32'd50);  // +3,+4: RP slot 1
    begin : zero_rp
        integer i;
        for (i = 2; i < MAX_SLOTS; i = i + 1) begin
            bram_write(32'd0); bram_write(32'd0);
        end
    end
    // RO, MW, veto all disabled (3 × 32 = 96 zero words)
    begin : zero_ro_mw_veto
        integer i;
        for (i = 0; i < MAX_SLOTS*2; i = i + 1) bram_write(32'd0); // RO
        for (i = 0; i < MAX_SLOTS*2; i = i + 1) bram_write(32'd0); // MW
        for (i = 0; i < MAX_SLOTS*2; i = i + 1) bram_write(32'd0); // veto
    end
    bram_write(32'd0); bram_write(32'd0); // sync disabled
    bram_write(32'd0); bram_write(32'd0); // mk0 disabled
    bram_write(32'd0); bram_write(32'd0); // mk1 disabled
    bram_write(32'd0); bram_write(32'd0); // mk2 disabled

    write_reg(7'h05, 32'd1);
    write_reg(7'h10, 32'd0);
    write_reg(7'h30, 32'd1);
    write_reg(7'h01, 32'd0);
    write_reg(7'h00, 32'd1);             // start

    repeat (160) @(posedge clk);         // wait for startup prefetch (~140 cycles)

    begin : multi_rp_check
        integer rp_hi;
        integer k;
        rp_hi = 0;
        for (k = 0; k < 400; k = k + 1) begin
            @(posedge clk);
            if (aom_rp_out) rp_hi = rp_hi + 1;
        end
        check("multi-slot RP high/period", rp_hi, 32'd80); // 30+50
    end

    write_reg(7'h00, 32'd2); // stop

    // ==========================================================================
    // Test 5: Veto signal — multi-slot, fires in designated cycle only
    // ct0: veto@5+10 and veto@50+8 (two slots), period=150
    // ct1: no veto, period=100
    // Sequence: [ct0 x1, ct1 x1], infinite.
    // Count one super-cycle (250 cycles): veto total should be 18 (10+8),
    // and veto should be 0 during the ct1 window within that period.
    // ==========================================================================
    $display("\n[5] Veto signal (multi-slot, isolated to ct0)");
    repeat (3) @(posedge clk);

    // Both seq_limits must be >= 140 for stall-free operation.
    write_cycle_type(
        3'd0,
        32'd200,                         // seq_limit
        32'd0,  32'd0,                   // RP disabled
        32'd0,  32'd0,                   // RO disabled
        32'd0,  32'd0,                   // MW disabled
        32'd5,  32'd10,                  // veto slot 0: @5 dur=10
        32'd0,  32'd0,                   // sync disabled
        32'd0,  32'd0                    // marker0 disabled
    );

    // Manually add veto slot 1 (@50 dur=8) to ct0 after write_cycle_type.
    // Slot 1 offset within the ct0 block: OFF_VETO + 1*2 = 97+2 = 99.
    // ct0 base = 0*256 = 0. BRAM word = 0 + 99 = 99.
    write_reg(7'h06, 32'd99);
    bram_write(32'd50); bram_write(32'd8); // veto slot 1: @50 dur=8

    write_cycle_type(
        3'd1,
        32'd200,                         // seq_limit
        32'd0,  32'd0,                   // RP disabled
        32'd0,  32'd0,                   // RO disabled
        32'd0,  32'd0,                   // MW disabled
        32'd0,  32'd0,                   // veto disabled
        32'd0,  32'd0,                   // sync disabled
        32'd0,  32'd0
    );

    write_reg(7'h05, 32'd2);
    write_reg(7'h10, 32'd0); write_reg(7'h30, 32'd1);
    write_reg(7'h11, 32'd1); write_reg(7'h31, 32'd1);
    write_reg(7'h01, 32'd0);             // infinite

    write_reg(7'h00, 32'd1);             // start

    repeat (160) @(posedge clk);

    // Count one complete super-cycle (400 cycles: 200 ct0 + 200 ct1).
    // Phase-independent: veto only fires during ct0, total = 10+8 = 18.
    begin : veto_check
        integer veto_hi;
        integer k;
        veto_hi = 0;
        for (k = 0; k < 400; k = k + 1) begin
            @(posedge clk);
            if (veto_out) veto_hi = veto_hi + 1;
        end
        check("veto high total/sc", veto_hi, 32'd18); // 10+8
    end

    write_reg(7'h00, 32'd2); // stop

    // ==========================================================================
    // Test 6: Finite super-cycle count (super_repeat_limit = 2)
    // 2-step sequence, total period = 200+300 = 500 cycles.
    // After 2 super-cycles sequencer should halt.
    // ==========================================================================
    $display("\n[6] Finite super-cycle count (limit=2)");
    repeat (3) @(posedge clk);

    write_cycle_type(
        3'd0, 32'd200,
        32'd10, 32'd50,  32'd0,  32'd0,  32'd0, 32'd0,
        32'd0,  32'd0,   32'd0,  32'd0,  32'd0, 32'd0
    );
    write_cycle_type(
        3'd1, 32'd300,
        32'd0,  32'd0,   32'd20, 32'd80, 32'd30, 32'd40,
        32'd0,  32'd0,   32'd0,  32'd10, 32'd0,  32'd0
    );

    write_reg(7'h05, 32'd2);
    write_reg(7'h10, 32'd0); write_reg(7'h30, 32'd1);
    write_reg(7'h11, 32'd1); write_reg(7'h31, 32'd1);
    write_reg(7'h01, 32'd2);             // SUPER_REPEAT_LIMIT = 2

    write_reg(7'h00, 32'd1);             // start

    // startup (~140) + 2 super-cycles (1000) + margin = 1300
    repeat (1300) @(posedge clk);

    read_reg(7'h00); check("finite: running stopped", avs_readdata[0], 1'd0);
    read_reg(7'h02); check("finite: super_count=2",   avs_readdata,    32'd2);

    // ==========================================================================
    // Test 7: SEQ_COUNT > 1 within a step (cal x3 + expt x1, 1 super-cycle)
    // ==========================================================================
    $display("\n[7] SEQ_COUNT=3 within a step");
    repeat (3) @(posedge clk);

    write_cycle_type(
        3'd0, 32'd200,
        32'd10, 32'd50,  32'd0,  32'd0,  32'd0, 32'd0,
        32'd0,  32'd0,   32'd0,  32'd0,  32'd0, 32'd0
    );
    write_cycle_type(
        3'd1, 32'd300,
        32'd0,  32'd0,   32'd20, 32'd80, 32'd30, 32'd40,
        32'd0,  32'd0,   32'd0,  32'd10, 32'd0,  32'd0
    );

    write_reg(7'h05, 32'd2);
    write_reg(7'h10, 32'd0); write_reg(7'h30, 32'd3); // cal x3
    write_reg(7'h11, 32'd1); write_reg(7'h31, 32'd1); // expt x1
    write_reg(7'h01, 32'd1);             // one super-cycle then stop

    write_reg(7'h00, 32'd1);

    // 3*200 + 300 = 900 cycles + startup (~140) + margin = 1200
    repeat (1200) @(posedge clk);

    read_reg(7'h00); check("count=3: stopped",       avs_readdata[0], 1'd0);
    read_reg(7'h02); check("count=3: super_count=1", avs_readdata,    32'd1);

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
