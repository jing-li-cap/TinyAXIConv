`timescale 1ns/1ps

// ================================================================
// tb_system
// ------------------------------------------------
// 系统级完整流程：
//   1. 通过 AXI-Lite 写 9 个 kernel。
//   2. 通过 AXI-Lite 写 25 个 input scratchpad。
//   3. 写控制寄存器 bit0=start。
//   4. 等待 irq，读状态寄存器清 done。
//   5. 读 9 个 output scratchpad，验证结果均为 9。
// ================================================================
module tb_system;
    localparam ADDR_WIDTH = 12;
    localparam DATA_WIDTH = 32;
    localparam [11:0] ADDR_CTRL       = 12'h000;
    localparam [11:0] ADDR_STATUS     = 12'h004;
    localparam [11:0] ADDR_KERNEL     = 12'h008;
    localparam [11:0] ADDR_INPUT_BASE = 12'h080;
    localparam [11:0] ADDR_OUTPUT     = 12'h100;

    reg clk;
    reg rst_n;

    reg  [ADDR_WIDTH-1:0] s_axi_awaddr;
    reg                   s_axi_awvalid;
    wire                  s_axi_awready;
    reg  [DATA_WIDTH-1:0] s_axi_wdata;
    reg  [3:0]            s_axi_wstrb;
    reg                   s_axi_wvalid;
    wire                  s_axi_wready;
    wire [1:0]            s_axi_bresp;
    wire                  s_axi_bvalid;
    reg                   s_axi_bready;
    reg  [ADDR_WIDTH-1:0] s_axi_araddr;
    reg                   s_axi_arvalid;
    wire                  s_axi_arready;
    wire [DATA_WIDTH-1:0] s_axi_rdata;
    wire [1:0]            s_axi_rresp;
    wire                  s_axi_rvalid;
    reg                   s_axi_rready;
    wire                  irq;

    integer i;
    integer errors;
    reg [31:0] read_value;

    top #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .irq(irq)
    );

    always #5 clk = ~clk;

    task reset_dut;
        begin
            clk = 1'b0;
            rst_n = 1'b0;
            s_axi_awaddr  = 12'h000;
            s_axi_awvalid = 1'b0;
            s_axi_wdata   = 32'h0000_0000;
            s_axi_wstrb   = 4'h0;
            s_axi_wvalid  = 1'b0;
            s_axi_bready  = 1'b0;
            s_axi_araddr  = 12'h000;
            s_axi_arvalid = 1'b0;
            s_axi_rready  = 1'b0;
            errors = 0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            $display("[%0t] RESET done", $time);
        end
    endtask

    task axi_write;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        begin
            $display("[%0t] AXI WRITE addr=0x%03h data=0x%08h", $time, addr, data);
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;
            #1;

            while (s_axi_awvalid || s_axi_wvalid) begin
                @(posedge clk);
                if (s_axi_awvalid && s_axi_awready) s_axi_awvalid <= 1'b0;
                if (s_axi_wvalid  && s_axi_wready)  s_axi_wvalid  <= 1'b0;
                #1;
            end

            while (!s_axi_bvalid) @(posedge clk);
            if (s_axi_bresp != 2'b00) begin
                $display("  ERROR: BRESP is not OKAY");
                errors = errors + 1;
            end
            @(posedge clk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task axi_read;
        input  [ADDR_WIDTH-1:0] addr;
        output [DATA_WIDTH-1:0] data;
        begin
            $display("[%0t] AXI READ addr=0x%03h", $time, addr);
            @(posedge clk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;
            #1;

            while (s_axi_arvalid) begin
                @(posedge clk);
                if (s_axi_arready) s_axi_arvalid <= 1'b0;
                #1;
            end

            while (!s_axi_rvalid) @(posedge clk);
            data = s_axi_rdata;
            $display("[%0t] AXI READ DATA addr=0x%03h data=%0d (0x%08h)",
                     $time, addr, $signed(data), data);
            if (s_axi_rresp != 2'b00) begin
                $display("  ERROR: RRESP is not OKAY");
                errors = errors + 1;
            end
            @(posedge clk);
            s_axi_rready <= 1'b0;
        end
    endtask

    initial begin
        reset_dut();

        $display("---- Configure kernel: all ones ----");
        for (i = 0; i < 9; i = i + 1) begin
            axi_write(ADDR_KERNEL + i*4, 32'h0000_0001);
        end

        $display("---- Configure input scratchpad: all ones ----");
        for (i = 0; i < 25; i = i + 1) begin
            axi_write(ADDR_INPUT_BASE + i*4, 32'h0000_0001);
        end

        $display("---- Trigger accelerator ----");
        axi_write(ADDR_CTRL, 32'h0000_0001);

        $display("[%0t] WAIT irq", $time);
        wait (irq);
        $display("[%0t] IRQ asserted", $time);

        axi_read(ADDR_STATUS, read_value);
        if (read_value[0] !== 1'b1) begin
            $display("  FAIL status.done: got=%0d expected=1", read_value[0]);
            errors = errors + 1;
        end else begin
            $display("  PASS status.done = 1, read should clear irq");
        end

        repeat (2) @(posedge clk);
        if (irq !== 1'b0) begin
            $display("  FAIL irq should be cleared after status read");
            errors = errors + 1;
        end else begin
            $display("  PASS irq cleared after status read");
        end

        $display("---- Read output scratchpad ----");
        for (i = 0; i < 9; i = i + 1) begin
            axi_read(ADDR_OUTPUT + i*4, read_value);
            if ($signed(read_value) !== 32'sd9) begin
                $display("  FAIL output[%0d]: got=%0d expected=9", i, $signed(read_value));
                errors = errors + 1;
            end else begin
                $display("  PASS output[%0d] = 9", i);
            end
        end

        if (errors == 0) begin
            $display("TB_SYSTEM PASS");
        end else begin
            $display("TB_SYSTEM FAIL errors=%0d", errors);
        end
        $finish;
    end
endmodule
