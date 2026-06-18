// =============================================================================
// pocketroll_recycle_tb.v — self-checking testbench for pocketroll_recycle.v
// -----------------------------------------------------------------------------
// Drives the recycle FSM against a known directory state and checks the result
// matches GROUND TRUTH from the real camera (docs/02-slot-recycling.md):
//
//   Input  = "before-del" directory: 2 photos, slots 0 and 1
//            0x11B2: 00 01 FF…FF · Magic · checksum 14 14 · echo
//   Action = free gallery position 1 (the slot-1 entry)
//   Expect = directory 00 FF FF…FF · checksum 12 EA · echo mirrored
//            (identical to what the camera itself produced when it deleted slot 1)
//
// Run it (tiny install, no Quartus needed):
//   iverilog -o rc_tb core/pocketroll_recycle.v core/tb/pocketroll_recycle_tb.v
//   vvp rc_tb
//
// ⚠️ Authored but NOT executed here (no simulator on the dev box). The RAM model
// is combinational-read / registered-write, matching the FSM's assumption.
// =============================================================================

`timescale 1ns/1ps

module pocketroll_recycle_tb;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [4:0]  gallery_pos = 0;
    wire        busy, done;

    wire [16:0] ram_addr;
    wire        ram_rd;
    reg  [7:0]  ram_rd_data;
    wire        ram_wr;
    wire [7:0]  ram_wr_data;

    // --- 128 KB byte RAM: combinational read, registered write ---------------
    reg [7:0] mem [0:131071];
    always @(*) ram_rd_data = mem[ram_addr];
    always @(posedge clk) if (ram_wr) mem[ram_addr] <= ram_wr_data;

    // --- DUT -----------------------------------------------------------------
    pocketroll_recycle dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .gallery_pos(gallery_pos), .busy(busy), .done(done),
        .ram_addr(ram_addr), .ram_rd(ram_rd), .ram_rd_data(ram_rd_data),
        .ram_wr(ram_wr), .ram_wr_data(ram_wr_data)
    );

    always #5 clk = ~clk;   // 100 MHz

    integer i, errors = 0;

    // expected echo helper
    task check;
        input [16:0] addr;
        input [7:0]  exp;
        begin
            if (mem[addr] !== exp) begin
                $display("  FAIL @0x%05h : got %02h, expected %02h", addr, mem[addr], exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // ---- preload the "before-del" management area (2 photos) -------------
        for (i = 0; i < 131072; i = i + 1) mem[i] = 8'h00;
        mem['h11B2] = 8'h00;                                   // directory: slot 0
        mem['h11B3] = 8'h01;                                   //            slot 1
        for (i = 'h11B4; i <= 'h11CF; i = i + 1) mem[i] = 8'hFF; // rest empty
        mem['h11D0]=8'h4D; mem['h11D1]=8'h61; mem['h11D2]=8'h67; // "Magic"
        mem['h11D3]=8'h69; mem['h11D4]=8'h63;
        mem['h11D5]=8'h14; mem['h11D6]=8'h14;                  // checksum (before)
        for (i = 0; i < 37; i = i + 1) mem['h11D7 + i] = mem['h11B2 + i]; // echo

        // ---- run: free gallery position 1 -----------------------------------
        #20 rst_n = 1;
        #20 gallery_pos = 5'd1; start = 1;
        #10 start = 0;

        wait (done);
        #10;

        // ---- check against ground truth -------------------------------------
        $display("pocketroll_recycle_tb: checking result of free(pos=1)");
        check('h11B2, 8'h00);   // slot 0 kept
        check('h11B3, 8'hFF);   // slot 1 freed
        check('h11D5, 8'h12);   // checksum sum  (validated vs camera)
        check('h11D6, 8'hEA);   // checksum xor
        // echo must mirror 0x11B2..0x11D6
        for (i = 0; i < 37; i = i + 1) check('h11D7 + i, mem['h11B2 + i]);

        if (errors == 0)
            $display("  ✅ PASS — recycle output matches the real camera's deletion.");
        else
            $display("  ❌ %0d mismatch(es).", errors);

        $finish;
    end

    // safety timeout
    initial begin #100000 $display("TIMEOUT"); $finish; end

endmodule
