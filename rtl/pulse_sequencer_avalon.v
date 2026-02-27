`timescale 1ns/1ps

module pulse_sequencer_avalon (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM Slave Interface
    input  wire [4:0]  avs_s0_address,
    input  wire        avs_s0_write,
    input  wire [31:0] avs_s0_writedata,
    input  wire        avs_s0_read,
    output reg  [31:0] avs_s0_readdata,

    // Physical Outputs
    output reg         aom_rp_out,
    output reg         aom_ro_out,
    output reg         sync_out       // Active-low; idles high
);

    // --- Register File ---
    reg [31:0] rp_start, rp_dur;
    reg [31:0] ro_start, ro_dur;
    reg [31:0] sync_start;
    reg [31:0] seq_limit;
    reg [31:0] repeat_limit;

    // --- Internal State ---
    reg        start_trigger;
    reg        stop_req;
    reg        running;
    reg [31:0] timer;
    reg [31:0] repeat_count;

    // Register map:
    //   0x00  Control / Status  (W: bit0=start, bit1=stop | R: bit0=running)
    //   0x01  seq_limit         Period length in clock cycles
    //   0x02  rp_start          RP AOM pulse start (cycles from period start)
    //   0x03  rp_dur            RP AOM pulse duration (cycles)
    //   0x04  ro_start          RO AOM pulse start
    //   0x05  ro_dur            RO AOM pulse duration
    //   0x06  sync_start        Sync pulse start (duration fixed at SYNC_DUR_FIXED)
    //   0x07  repeat_limit      0 = infinite; N = run N periods then stop
    //   0x08  repeat_count      R/O: number of period resets completed since start

    localparam SYNC_DUR_FIXED = 32'd20;

    // -------------------------------------------------------------------------
    // Avalon-MM Write Logic
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rp_start      <= 0;
            rp_dur        <= 0;
            ro_start      <= 0;
            ro_dur        <= 0;
            sync_start    <= 0;
            seq_limit     <= 32'd5000;
            repeat_limit  <= 32'd1;
            start_trigger <= 0;
            stop_req      <= 0;
        end else begin
            // One-cycle strobes; auto-clear each cycle so the engine sees
            // exactly one pulse regardless of how long the host holds the write.
            start_trigger <= 0;
            stop_req      <= 0;

            if (avs_s0_write) begin
                case (avs_s0_address)
                    5'h00: begin
                        start_trigger <= avs_s0_writedata[0];
                        stop_req      <= avs_s0_writedata[1];
                    end
                    5'h01: seq_limit    <= avs_s0_writedata;
                    5'h02: rp_start     <= avs_s0_writedata;
                    5'h03: rp_dur       <= avs_s0_writedata;
                    5'h04: ro_start     <= avs_s0_writedata;
                    5'h05: ro_dur       <= avs_s0_writedata;
                    5'h06: sync_start   <= avs_s0_writedata;
                    5'h07: repeat_limit <= avs_s0_writedata;
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Avalon-MM Read Logic  (read latency = 1 cycle)
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            avs_s0_readdata <= 32'd0;
        end else if (avs_s0_read) begin
            case (avs_s0_address)
                5'h00: avs_s0_readdata <= {31'd0, running};
                5'h01: avs_s0_readdata <= seq_limit;
                5'h02: avs_s0_readdata <= rp_start;
                5'h03: avs_s0_readdata <= rp_dur;
                5'h04: avs_s0_readdata <= ro_start;
                5'h05: avs_s0_readdata <= ro_dur;
                5'h06: avs_s0_readdata <= sync_start;
                5'h07: avs_s0_readdata <= repeat_limit;
                5'h08: avs_s0_readdata <= repeat_count;
                default: avs_s0_readdata <= 32'hDEADBEEF;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Pulse Generation Engine
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            timer        <= 32'd0;
            repeat_count <= 32'd0;
            running      <= 1'b0;
            aom_rp_out   <= 1'b0;
            aom_ro_out   <= 1'b0;
            sync_out     <= 1'b1;
        end else begin

            // Start: only honoured when idle
            if (start_trigger && !running) begin
                running      <= 1'b1;
                timer        <= 32'd0;
                repeat_count <= 32'd0;
            end

            // Stop: immediate halt; takes priority over the running branch below
            if (stop_req && running) begin
                running    <= 1'b0;
                aom_rp_out <= 1'b0;
                aom_ro_out <= 1'b0;
                sync_out   <= 1'b1;
            end else if (running) begin
                timer <= timer + 1;

                // All comparisons use the current (pre-increment) value of timer,
                // so outputs are registered one cycle after the timer value that
                // qualified them -- this is a predictable, fixed one-cycle latency.
                aom_rp_out <= (timer >= rp_start) && (timer < (rp_start + rp_dur));
                aom_ro_out <= (timer >= ro_start) && (timer < (ro_start + ro_dur));
                sync_out   <= ~((timer >= sync_start) && (timer < (sync_start + SYNC_DUR_FIXED)));

                // End-of-period: using >= so a mid-run seq_limit reduction is
                // caught without waiting for the timer to wrap.
                // NOTE: seq_limit = 0 is illegal; minimum useful value is 1.
                if (timer >= seq_limit - 1) begin
                    if ((repeat_limit == 0) || (repeat_count + 1 < repeat_limit)) begin
                        // Loop: reset timer, count the completed period
                        timer        <= 32'd0;
                        repeat_count <= repeat_count + 1;
                    end else begin
                        // Done: deassert all outputs cleanly
                        running    <= 1'b0;
                        aom_rp_out <= 1'b0;
                        aom_ro_out <= 1'b0;
                        sync_out   <= 1'b1;
                    end
                end
            end

        end
    end

endmodule
