module avalon_waveform_wrapper (
    input  wire        clk,
    input  wire        reset_n,
    
    // --- Avalon-MM Slave Interface (Connects to HPS) ---
    // The HPS sees this module as a chunk of memory.
    input  wire [10:0] avs_address,     // 11 bits (Range 0-2047)
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire        avs_read,
    output reg  [31:0] avs_readdata,

    // --- Conduit Interface (Connects to DAC pins) ---
    // These signals leave the chip or go to other FPGA modules.
    output wire [13:0] conduit_dac_out
);

    // --- Internal Configuration Registers ---
    // These hold the settings "Run" and "Speed"
    reg [31:0] reg_divider;
    reg        reg_run;

    // --- Address Decoding ---
    // 0 - 1023  : RAM Access
    // 1024      : Control Register (Start/Stop)
    // 1025      : Divider Register (Speed)
    
    wire is_ram_access = (avs_address < 1024);
    wire is_cfg_access = (avs_address >= 1024);

    // --- Instantiate Unit 1 (The Engine) ---
    waveform_engine #(
        .ADDR_WIDTH(10),
        .DATA_WIDTH(14)
    ) engine_inst (
        .clk(clk),
        .reset_n(reset_n),
        
        // --- The Router Logic ---
        // Only trigger a RAM write if the address is in the 0-1023 range
        .load_we   (avs_write && is_ram_access), 
        .load_addr (avs_address[9:0]),           // Strip top bit, keep [9:0]
        .load_data (avs_writedata[13:0]),        // Take bottom 14 bits of data
        
        // Control Signals from our internal registers
        .ctrl_run    (reg_run),
        .cfg_divider (reg_divider),
        .dac_out     (conduit_dac_out)
    );

    // --- Write Logic (Processor -> FPGA) ---
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_run     <= 0;
            reg_divider <= 50; // Default: Slow speed (1 MHz)
        end else if (avs_write && is_cfg_access) begin
            // We only care if the address is >= 1024
            case (avs_address)
                11'd1024: reg_run     <= avs_writedata[0]; // Bit 0 is Run/Stop
                11'd1025: reg_divider <= avs_writedata;    // Whole word is Divider
            endcase
        end
    end

    // --- Read Logic (FPGA -> Processor) ---
    // This allows Python to check "Is it running?" or "What is the divider?"
    always @(posedge clk) begin
        if (avs_read) begin
            if (is_cfg_access) begin
                case (avs_address)
                    11'd1024: avs_readdata <= {31'b0, reg_run};
                    11'd1025: avs_readdata <= reg_divider;
                    default:  avs_readdata <= 32'b0;
                endcase
            end else begin
                // Reading back RAM is optional. 
                // Return a debug value so we know the bus is working.
                avs_readdata <= 32'hDEADBEEF; 
            end
        end
    end

endmodule