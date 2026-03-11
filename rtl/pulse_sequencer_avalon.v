`timescale 1ns/1ps

// pulse_sequencer_avalon.v
//
// NV center pulse sequencer with:
//   - Super-cycle: configurable sequence of up to MAX_SEQ_LEN steps,
//     each specifying a cycle type index and a repeat count
//   - Up to MAX_CYCLE_TYPES unique cycle type definitions stored in BRAM
//   - Up to MAX_SLOTS pulse slots per channel per cycle type
//   - Outputs: RP AOM, RO AOM, MW switch, veto, sync (active-low),
//              PicoHarp markers
//   - Double-buffered config prefetch: zero dead-time between cycle types
//     (requires seq_limit >= WORDS_PER_CYCLE+2 cycles; see notes below)
//
// Avalon-MM register map (7-bit word address):
//   0x00  CONTROL             W: bit0=start strobe, bit1=stop strobe
//                             R: bit0=running
//   0x01  SUPER_REPEAT_LIMIT  0=infinite, N=halt after N complete super-cycles
//   0x02  SUPER_REPEAT_COUNT  R/O: super-cycles completed since last start
//   0x03  STATUS_EXT          R/O: {running, active_bank, prefetch_active,
//                                   3'b0, seq_pos[4:0]}
//   0x04  TIMER_SNAPSHOT      R/O: timer value latched at read
//   0x05  SEQ_LEN             Number of valid sequence entries (1..MAX_SEQ_LEN)
//   0x06  CONFIG_BRAM_ADDR    Write to set BRAM word-address pointer
//   0x07  CONFIG_BRAM_DATA    R/W BRAM[ptr]; writes auto-increment ptr
//   0x10..0x2F  SEQ_TYPE[0..31]   cycle-type index for each sequence position
//   0x30..0x4F  SEQ_COUNT[0..31]  repeat count for each sequence position
//
// BRAM layout (256 words per cycle type, base = cycle_type_index * 256):
//   +0          seq_limit
//   +1..+32     rp_start[0],rp_dur[0], rp_start[1],rp_dur[1], ... [15]
//   +33..+64    ro_start[0],ro_dur[0], ...                          [15]
//   +65..+96    mw_start[0],mw_dur[0], ...                          [15]
//   +97..+128   veto_start[0],veto_dur[0], ...                      [15]
//   +129        sync_start
//   +130        sync_dur        (0 = disabled for this cycle)
//   +131,+132   mk0_start, mk0_dur   (dur=0 = disabled)
//   +133,+134   mk1_start, mk1_dur
//   +135,+136   mk2_start, mk2_dur
//   +137..+255  reserved
//
// Double-buffered prefetch notes:
//   Two config banks (A and B) alternate: one is active (drives comparators),
//   the other is the shadow (being loaded from BRAM in the background).
//   At every cycle-type transition the banks swap in one clock, giving
//   zero dead-time as long as the BRAM load completed during the previous
//   cycle.  If seq_limit < WORDS_PER_CYCLE+2, a brief stall is inserted.
//   The only unavoidable delay is the ~2 µs startup load before the first
//   cycle begins.

module pulse_sequencer_avalon #(
    parameter MAX_CYCLE_TYPES = 8,
    parameter MAX_SLOTS       = 16,
    parameter MAX_SEQ_LEN     = 32,
    parameter NUM_MARKERS     = 3
) (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM slave (7-bit word address, 32-bit data)
    input  wire [6:0]  avs_s0_address,
    input  wire        avs_s0_write,
    input  wire [31:0] avs_s0_writedata,
    input  wire        avs_s0_read,
    output reg  [31:0] avs_s0_readdata,

    // Pulse outputs
    output reg         aom_rp_out,                  // RP AOM (active-high)
    output reg         aom_ro_out,                  // RO AOM (active-high)
    output reg         mw_out,                      // MW switch (active-high)
    output reg         veto_out,                    // PicoHarp veto (active-high)
    output reg         sync_out,                    // Sync (active-low, idles high)
    output reg [NUM_MARKERS-1:0] marker_out         // PicoHarp markers (active-high)
);

// ---------------------------------------------------------------------------
// Derived constants
// ---------------------------------------------------------------------------
localparam BRAM_DEPTH      = MAX_CYCLE_TYPES * 256;       // 2048
localparam WORDS_PER_CYCLE = 1 + MAX_SLOTS*8 + 2 + NUM_MARKERS*2; // 137

// BRAM word offsets within a cycle-type block
localparam OFF_SEQ_LIMIT = 0;
localparam OFF_RP        = 1;               // [+1..+32]
localparam OFF_RO        = 1 + MAX_SLOTS*2; // [+33..+64]
localparam OFF_MW        = 1 + MAX_SLOTS*4; // [+65..+96]
localparam OFF_VETO      = 1 + MAX_SLOTS*6; // [+97..+128]
localparam OFF_SYNC_ST   = 1 + MAX_SLOTS*8; // +129
localparam OFF_SYNC_DUR  = 2 + MAX_SLOTS*8; // +130
localparam OFF_MK_BASE   = 3 + MAX_SLOTS*8; // +131 (mk0_start), +132 (mk0_dur), ...

// FSM states
localparam ST_IDLE    = 2'd0;
localparam ST_STARTUP = 2'd1;
localparam ST_RUNNING = 2'd2;

// ---------------------------------------------------------------------------
// Avalon register file
// ---------------------------------------------------------------------------
reg [31:0] reg_super_limit;
reg [31:0] reg_seq_len;
reg [31:0] seq_type  [0:MAX_SEQ_LEN-1];
reg [31:0] seq_count [0:MAX_SEQ_LEN-1];
reg [10:0] bram_avl_addr;

// One-cycle command strobes decoded from Avalon writes
reg start_trigger;
reg stop_req;

// ---------------------------------------------------------------------------
// Dual-port BRAM
//   Port A: Avalon R/W  — cycle-type configuration written by Python
//   Port B: prefetch    — hardware background loader (read-only)
// Quartus infers M10K simple dual-port RAM from this pattern.
// ---------------------------------------------------------------------------
reg [31:0] bram [0:BRAM_DEPTH-1];
reg [31:0] bram_pa_dout;            // port A registered read output
reg [10:0] bram_pb_addr;            // port B read address
reg [31:0] bram_pb_dout;            // port B registered read output

always @(posedge clk) begin
    if (avs_s0_write && avs_s0_address == 7'h07)
        bram[bram_avl_addr] <= avs_s0_writedata;
    bram_pa_dout <= bram[bram_avl_addr]; // port A read (1-cycle latency)
    bram_pb_dout <= bram[bram_pb_addr];  // port B read (1-cycle latency)
end

// ---------------------------------------------------------------------------
// Avalon write logic
// ---------------------------------------------------------------------------
always @(posedge clk or negedge reset_n) begin : avl_write
    integer i;
    if (!reset_n) begin
        start_trigger   <= 1'b0;
        stop_req        <= 1'b0;
        reg_super_limit <= 32'd0;   // 0 = infinite
        reg_seq_len     <= 32'd1;
        bram_avl_addr   <= 11'd0;
        for (i = 0; i < MAX_SEQ_LEN; i = i + 1) begin
            seq_type[i]  <= 32'd0;
            seq_count[i] <= 32'd1;
        end
    end else begin
        start_trigger <= 1'b0;
        stop_req      <= 1'b0;

        if (avs_s0_write) begin
            casez (avs_s0_address)
                7'h00: begin
                    start_trigger <= avs_s0_writedata[0];
                    stop_req      <= avs_s0_writedata[1];
                end
                7'h01: reg_super_limit <= avs_s0_writedata;
                7'h05: reg_seq_len     <= avs_s0_writedata;
                7'h06: bram_avl_addr   <= avs_s0_writedata[10:0];
                7'h07: bram_avl_addr   <= bram_avl_addr + 1; // auto-increment on write
                // SEQ_TYPE[0..15]  @ 0x10..0x1F  (bits[6:4]=001, index={0,addr[3:0]})
                7'b001????: seq_type[ {1'b0, avs_s0_address[3:0]} ] <= avs_s0_writedata;
                // SEQ_TYPE[16..31] @ 0x20..0x2F  (bits[6:4]=010, index={1,addr[3:0]})
                7'b010????: seq_type[ {1'b1, avs_s0_address[3:0]} ] <= avs_s0_writedata;
                // SEQ_COUNT[0..15] @ 0x30..0x3F  (bits[6:4]=011)
                7'b011????: seq_count[ {1'b0, avs_s0_address[3:0]} ] <= avs_s0_writedata;
                // SEQ_COUNT[16..31]@ 0x40..0x4F  (bits[6:4]=100)
                7'b100????: seq_count[ {1'b1, avs_s0_address[3:0]} ] <= avs_s0_writedata;
                default: ; // R/O addresses silently ignored on write
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// Avalon read logic (1-cycle latency)
// ---------------------------------------------------------------------------
reg        running;
reg        active_bank;
reg [4:0]  seq_pos;
reg        prefetch_busy;   // prefetch in progress
reg [31:0] reg_super_count;
reg [31:0] timer;
reg [31:0] timer_snapshot;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        avs_s0_readdata <= 32'd0;
        timer_snapshot  <= 32'd0;
    end else begin
        if (avs_s0_read && avs_s0_address == 7'h04)
            timer_snapshot <= timer;    // latch timer on read

        if (avs_s0_read) begin
            casez (avs_s0_address)
                7'h00: avs_s0_readdata <= {31'd0, running};
                7'h01: avs_s0_readdata <= reg_super_limit;
                7'h02: avs_s0_readdata <= reg_super_count;
                7'h03: avs_s0_readdata <= {24'd0, running, active_bank,
                                            prefetch_busy, 3'd0, seq_pos};
                7'h04: avs_s0_readdata <= timer_snapshot;
                7'h05: avs_s0_readdata <= reg_seq_len;
                7'h06: avs_s0_readdata <= {21'd0, bram_avl_addr};
                7'h07: avs_s0_readdata <= bram_pa_dout;
                7'b001????: avs_s0_readdata <= seq_type[ {1'b0, avs_s0_address[3:0]} ];
                7'b010????: avs_s0_readdata <= seq_type[ {1'b1, avs_s0_address[3:0]} ];
                7'b011????: avs_s0_readdata <= seq_count[ {1'b0, avs_s0_address[3:0]} ];
                7'b100????: avs_s0_readdata <= seq_count[ {1'b1, avs_s0_address[3:0]} ];
                default:    avs_s0_readdata <= 32'd0;
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// Double-buffered active config banks
//   cfg[0] and cfg[1] each hold WORDS_PER_CYCLE 32-bit words.
//   active_bank selects which drives the comparators.
//   The shadow bank (~active_bank) receives the prefetch.
// ---------------------------------------------------------------------------
reg [31:0] cfg [0:1][0:WORDS_PER_CYCLE-1];

// ---------------------------------------------------------------------------
// Prefetch loader
//   When prefetch_req is strobed, loads WORDS_PER_CYCLE words from BRAM
//   port B into cfg[~active_bank], accounting for 1-cycle BRAM read latency.
//   Total load time: WORDS_PER_CYCLE + 1 clock cycles.
// ---------------------------------------------------------------------------
reg        prefetch_req;       // 1-cycle strobe from FSM
reg [2:0]  prefetch_type;      // cycle-type index to load
reg [7:0]  load_ptr;           // 0 .. WORDS_PER_CYCLE (pipeline counter)
reg [10:0] load_base;          // BRAM base for the current prefetch

always @(posedge clk or negedge reset_n) begin : prefetch_loader
    integer w;
    if (!reset_n) begin
        prefetch_busy <= 1'b0;
        load_ptr      <= 8'd0;
        bram_pb_addr  <= 11'd0;
        for (w = 0; w < WORDS_PER_CYCLE; w = w + 1) begin
            cfg[0][w] <= 32'd0;
            cfg[1][w] <= 32'd0;
        end
    end else begin
        if (prefetch_req) begin
            load_base    <= {prefetch_type, 8'd0}; // type * 256
            bram_pb_addr <= {prefetch_type, 8'd0};
            load_ptr     <= 8'd0;
            prefetch_busy <= 1'b1;
        end else if (prefetch_busy) begin
            // Advance read address (data appears one cycle later)
            if (load_ptr < WORDS_PER_CYCLE)
                bram_pb_addr <= load_base + load_ptr + 1;

            // Capture data into shadow bank (valid from cycle 1 onward)
            if (load_ptr >= 1 && load_ptr <= WORDS_PER_CYCLE)
                cfg[~active_bank][load_ptr - 1] <= bram_pb_dout;

            if (load_ptr == WORDS_PER_CYCLE)
                prefetch_busy <= 1'b0;

            load_ptr <= load_ptr + 1;
        end
    end
end

// ---------------------------------------------------------------------------
// Pulse comparators (combinatorial, reading from active bank)
// Outputs are registered in the FSM to give a clean 1-cycle latency.
// ---------------------------------------------------------------------------
reg rp_c, ro_c, mw_c, veto_c, sync_c;
reg [NUM_MARKERS-1:0] mk_c;

always @(*) begin : comparators
    integer s, m;
    rp_c   = 1'b0;
    ro_c   = 1'b0;
    mw_c   = 1'b0;
    veto_c = 1'b0;
    sync_c = 1'b0;
    mk_c   = {NUM_MARKERS{1'b0}};

    for (s = 0; s < MAX_SLOTS; s = s + 1) begin
        if (cfg[active_bank][OFF_RP + s*2 + 1] != 32'd0 &&
            timer >= cfg[active_bank][OFF_RP + s*2] &&
            timer <  cfg[active_bank][OFF_RP + s*2] +
                     cfg[active_bank][OFF_RP + s*2 + 1])
            rp_c = 1'b1;

        if (cfg[active_bank][OFF_RO + s*2 + 1] != 32'd0 &&
            timer >= cfg[active_bank][OFF_RO + s*2] &&
            timer <  cfg[active_bank][OFF_RO + s*2] +
                     cfg[active_bank][OFF_RO + s*2 + 1])
            ro_c = 1'b1;

        if (cfg[active_bank][OFF_MW + s*2 + 1] != 32'd0 &&
            timer >= cfg[active_bank][OFF_MW + s*2] &&
            timer <  cfg[active_bank][OFF_MW + s*2] +
                     cfg[active_bank][OFF_MW + s*2 + 1])
            mw_c = 1'b1;

        if (cfg[active_bank][OFF_VETO + s*2 + 1] != 32'd0 &&
            timer >= cfg[active_bank][OFF_VETO + s*2] &&
            timer <  cfg[active_bank][OFF_VETO + s*2] +
                     cfg[active_bank][OFF_VETO + s*2 + 1])
            veto_c = 1'b1;
    end

    sync_c = (cfg[active_bank][OFF_SYNC_DUR] != 32'd0 &&
              timer >= cfg[active_bank][OFF_SYNC_ST] &&
              timer <  cfg[active_bank][OFF_SYNC_ST] +
                       cfg[active_bank][OFF_SYNC_DUR]);

    for (m = 0; m < NUM_MARKERS; m = m + 1)
        mk_c[m] = (cfg[active_bank][OFF_MK_BASE + m*2 + 1] != 32'd0 &&
                   timer >= cfg[active_bank][OFF_MK_BASE + m*2] &&
                   timer <  cfg[active_bank][OFF_MK_BASE + m*2] +
                            cfg[active_bank][OFF_MK_BASE + m*2 + 1]);
end

// ---------------------------------------------------------------------------
// Main sequencer FSM
// ---------------------------------------------------------------------------
reg [1:0]  state;
reg [31:0] inner_count;

// Helpers used inside the FSM always block (blocking assignments, no storage)
reg [4:0]  to_pos;          // next seq_pos value (computed locally)
reg [2:0]  after_to_type;   // cycle type that comes after to_pos
reg        after_to_valid;  // is there a step after to_pos?

task deassert_outputs;
    begin
        aom_rp_out <= 1'b0;
        aom_ro_out <= 1'b0;
        mw_out     <= 1'b0;
        veto_out   <= 1'b0;
        sync_out   <= 1'b1;
        marker_out <= {NUM_MARKERS{1'b0}};
    end
endtask

// Compute the step that follows a given position (blocking, used in FSM).
// Results go into after_to_type and after_to_valid.
// NOTE: uses blocking assignments so values are available immediately.
task compute_after;
    input [4:0] pos;
    begin
        if (pos + 1 < reg_seq_len[4:0]) begin
            after_to_type  = seq_type[pos + 1][2:0];
            after_to_valid = 1'b1;
        end else if (reg_super_limit == 32'd0 ||
                     reg_super_count + 1 < reg_super_limit) begin
            after_to_type  = seq_type[0][2:0];
            after_to_valid = 1'b1;
        end else begin
            after_to_type  = 3'd0;
            after_to_valid = 1'b0;
        end
    end
endtask

always @(posedge clk or negedge reset_n) begin : sequencer
    if (!reset_n) begin
        state           <= ST_IDLE;
        running         <= 1'b0;
        active_bank     <= 1'b0;
        seq_pos         <= 5'd0;
        inner_count     <= 32'd0;
        timer           <= 32'd0;
        reg_super_count <= 32'd0;
        prefetch_req    <= 1'b0;
        prefetch_type   <= 3'd0;
        deassert_outputs();
    end else begin
        prefetch_req <= 1'b0; // default: no new prefetch this cycle

        case (state)

            // --------------------------------------------------------------
            ST_IDLE: begin
                deassert_outputs();
                running <= 1'b0;

                if (start_trigger) begin
                    seq_pos         <= 5'd0;
                    inner_count     <= 32'd0;
                    reg_super_count <= 32'd0;
                    active_bank     <= 1'b0;
                    // Kick off initial prefetch of step 0 into shadow (bank 1)
                    prefetch_req    <= 1'b1;
                    prefetch_type   <= seq_type[0][2:0];
                    state           <= ST_STARTUP;
                end
            end

            // --------------------------------------------------------------
            // Wait for initial prefetch to finish, then swap and start.
            ST_STARTUP: begin
                if (!prefetch_busy && !prefetch_req) begin
                    // Shadow bank (1) is loaded — make it active
                    active_bank <= ~active_bank;
                    timer       <= 32'd0;
                    running     <= 1'b1;
                    state       <= ST_RUNNING;

                    // Schedule prefetch for the step after step 0.
                    // to_pos = 0 here; after_to is step 1 (or wrap).
                    compute_after(5'd0);
                    if (after_to_valid) begin
                        prefetch_req  <= 1'b1;
                        prefetch_type <= after_to_type;
                    end
                end
            end

            // --------------------------------------------------------------
            ST_RUNNING: begin
                if (stop_req) begin
                    state <= ST_IDLE;
                    running <= 1'b0;
                    deassert_outputs();

                end else begin
                    // Register combinatorial pulse outputs (1-cycle latency)
                    aom_rp_out <= rp_c;
                    aom_ro_out <= ro_c;
                    mw_out     <= mw_c;
                    veto_out   <= veto_c;
                    sync_out   <= ~sync_c;
                    marker_out <= mk_c;

                    timer <= timer + 1;

                    if (timer >= cfg[active_bank][OFF_SEQ_LIMIT] - 1) begin
                        timer <= 32'd0;

                        if (inner_count + 1 < seq_count[seq_pos]) begin
                            // -----------------------------------------------
                            // Case A: repeat same cycle type.
                            // No bank swap. Prefetch of the next-different
                            // step is already running in the shadow bank.
                            inner_count <= inner_count + 1;

                        end else begin
                            // -----------------------------------------------
                            // Case B: last repeat — advance to next step.
                            // Wait if prefetch hasn't finished (rare stall).
                            if (prefetch_busy) begin
                                timer <= cfg[active_bank][OFF_SEQ_LIMIT] - 1;
                            end else begin
                                // Swap banks: prefetched config becomes active
                                active_bank <= ~active_bank;
                                inner_count <= 32'd0;

                                // Compute where we're advancing to
                                if (seq_pos + 1 < reg_seq_len[4:0]) begin
                                    to_pos = seq_pos + 1;
                                    seq_pos <= to_pos;
                                    // Prefetch what comes after to_pos
                                    compute_after(to_pos);
                                    if (after_to_valid) begin
                                        prefetch_req  <= 1'b1;
                                        prefetch_type <= after_to_type;
                                    end

                                end else begin
                                    // End of super-cycle
                                    reg_super_count <= reg_super_count + 1;

                                    if (reg_super_limit != 32'd0 &&
                                        reg_super_count + 1 >= reg_super_limit) begin
                                        // All done
                                        state   <= ST_IDLE;
                                        running <= 1'b0;
                                        deassert_outputs();
                                    end else begin
                                        // Loop: restart at step 0
                                        to_pos  = 5'd0;
                                        seq_pos <= to_pos;
                                        // Prefetch what comes after step 0
                                        compute_after(to_pos);
                                        if (after_to_valid) begin
                                            prefetch_req  <= 1'b1;
                                            prefetch_type <= after_to_type;
                                        end
                                    end
                                end
                            end // !prefetch_busy
                        end
                    end // end-of-period

                end // !stop_req
            end // ST_RUNNING

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
