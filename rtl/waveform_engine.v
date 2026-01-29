module waveform_engine #(
    parameter ADDR_WIDTH = 10, // 2^10 = 1024 samples
    parameter DATA_WIDTH = 14  // 14-bit DAC resolution
)(
    input wire clk,          // System Clock (50MHz now, 165MHz later)
    input wire reset_n,      // Active-low Reset
    
    // --- Loading Interface (Port A) ---
    // This is how we will eventually get data from Python
    input  wire                  load_we,      // Write Enable
    input  wire [ADDR_WIDTH-1:0] load_addr,    // Address to write (0-1023)
    input  wire [DATA_WIDTH-1:0] load_data,    // Data to write
    
    // --- Control Interface ---
    input  wire                  ctrl_run,     // 1 = Play, 0 = Pause/Reset
    input  wire [31:0]           cfg_divider,  // Clock cycles per sample (Sample Rate)
                                               // e.g. 50MHz / 50 = 1MHz Sample Rate
    
    // --- Output Interface (Port B) ---
    output reg  [DATA_WIDTH-1:0] dac_out       // The 14-bit signal going to pins
);

    // 1. Infer the RAM (1024 x 14-bit)
    // This syntax tells Quartus/ModelSim to create a memory block
    reg [DATA_WIDTH-1:0] ram_block [0:(1<<ADDR_WIDTH)-1];

    // Port A: The "Writer" (Python side)
    always @(posedge clk) begin
        if (load_we) begin
            ram_block[load_addr] <= load_data;
        end
    end

    // 2. Playback Logic
    reg [31:0]           div_counter;  // Counts clock cycles
    reg [ADDR_WIDTH-1:0] read_ptr;     // Points to current sample (0-1023)
    
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            div_counter <= 0;
            read_ptr    <= 0;
            dac_out     <= 0;
        end else if (ctrl_run) begin
            // --- Running Mode ---
            
            if (div_counter >= cfg_divider - 1) begin
                // Time to move to next sample!
                div_counter <= 0;
                
                // Increment pointer and wrap around (Modulo math)
                read_ptr <= read_ptr + 1'b1; 
                
                // Fetch new data from RAM to Output
                // (This is a Synchronous Read)
                dac_out <= ram_block[read_ptr];
                
            end else begin
                // Not time yet, keep counting
                div_counter <= div_counter + 1;
            end
            
        end else begin
            // --- Stopped Mode ---
            div_counter <= 0;
            read_ptr    <= 0;
            // Optional: Keep holding the last value, or reset to 0?
            // Usually safest to reset DAC to 0 or mid-scale.
            dac_out     <= 0; 
        end
    end

endmodule
