`timescale 1ns/1ps

// ================================================================
// tb_axi_lite
// ------------------------------------------------
// 单独验证 axi_lite_slave 的五通道握手：
//   1. AW/W 同时到达。
//   2. AW 先到、W 后到。
//   3. W 先到、AW 后到。
//   4. 读事务返回前面写入的数据。
// ================================================================
module tb_axi_lite;
    localparam ADDR_WIDTH = 12;
    localparam DATA_WIDTH = 32;

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

    wire                  wr_en;
    wire [ADDR_WIDTH-1:0] wr_addr;
    wire [DATA_WIDTH-1:0] wr_data;
    wire [3:0]            wr_strb;
    wire                  rd_en;
    wire [ADDR_WIDTH-1:0] rd_addr;
    wire [DATA_WIDTH-1:0] rd_data;

    reg [31:0] mock_mem [0:255];
    integer i;
    integer errors;
    reg [31:0] read_value;

    axi_lite_slave #(
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
        .wr_en(wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .wr_strb(wr_strb),
        .rd_en(rd_en),
        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    assign rd_data = mock_mem[rd_addr[9:2]];

    // 简单 mock 寄存器文件，验证从机转出的 wr_en/addr/data/strb。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 256; i = i + 1) begin
                mock_mem[i] <= 32'h0000_0000;
            end
        end else if (wr_en) begin
            $display("[%0t] MOCK WRITE addr=0x%03h data=0x%08h strb=0x%1h",
                     $time, wr_addr, wr_data, wr_strb);
            if (wr_strb[0]) mock_mem[wr_addr[9:2]][7:0]   <= wr_data[7:0];
            if (wr_strb[1]) mock_mem[wr_addr[9:2]][15:8]  <= wr_data[15:8];
            if (wr_strb[2]) mock_mem[wr_addr[9:2]][23:16] <= wr_data[23:16];
            if (wr_strb[3]) mock_mem[wr_addr[9:2]][31:24] <= wr_data[31:24];
        end
    end

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

    task axi_write_together;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        begin
            $display("[%0t] AXI WRITE together addr=0x%03h data=0x%08h", $time, addr, data);
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

    task axi_write_aw_first;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        begin
            $display("[%0t] AXI WRITE AW-first addr=0x%03h data=0x%08h", $time, addr, data);
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_bready  <= 1'b1;
            #1;
            while (s_axi_awvalid) begin
                @(posedge clk);
                if (s_axi_awready) s_axi_awvalid <= 1'b0;
                #1;
            end

            repeat (2) @(posedge clk);
            s_axi_wdata  <= data;
            s_axi_wstrb  <= 4'hF;
            s_axi_wvalid <= 1'b1;
            #1;
            while (s_axi_wvalid) begin
                @(posedge clk);
                if (s_axi_wready) s_axi_wvalid <= 1'b0;
                #1;
            end

            while (!s_axi_bvalid) @(posedge clk);
            @(posedge clk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task axi_write_w_first;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        begin
            $display("[%0t] AXI WRITE W-first addr=0x%03h data=0x%08h", $time, addr, data);
            @(posedge clk);
            s_axi_wdata  <= data;
            s_axi_wstrb  <= 4'hF;
            s_axi_wvalid <= 1'b1;
            s_axi_bready <= 1'b1;
            #1;
            while (s_axi_wvalid) begin
                @(posedge clk);
                if (s_axi_wready) s_axi_wvalid <= 1'b0;
                #1;
            end

            repeat (2) @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            #1;
            while (s_axi_awvalid) begin
                @(posedge clk);
                if (s_axi_awready) s_axi_awvalid <= 1'b0;
                #1;
            end

            while (!s_axi_bvalid) @(posedge clk);
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
            $display("[%0t] AXI READ DATA addr=0x%03h data=0x%08h", $time, addr, data);
            if (s_axi_rresp != 2'b00) begin
                $display("  ERROR: RRESP is not OKAY");
                errors = errors + 1;
            end
            @(posedge clk);
            s_axi_rready <= 1'b0;
        end
    endtask

    task expect_eq;
        input [31:0] got;
        input [31:0] exp;
        input [127:0] name;
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got=0x%08h expected=0x%08h", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("  PASS %0s: value=0x%08h", name, got);
            end
        end
    endtask

    initial begin
        reset_dut();

        axi_write_together(12'h020, 32'hA5A5_5A5A);
        axi_read(12'h020, read_value);
        expect_eq(read_value, 32'hA5A5_5A5A, "together");

        axi_write_aw_first(12'h024, 32'h1122_3344);
        axi_read(12'h024, read_value);
        expect_eq(read_value, 32'h1122_3344, "aw_first");

        axi_write_w_first(12'h028, 32'h5566_7788);
        axi_read(12'h028, read_value);
        expect_eq(read_value, 32'h5566_7788, "w_first");

        if (errors == 0) begin
            $display("TB_AXI_LITE PASS");
        end else begin
            $display("TB_AXI_LITE FAIL errors=%0d", errors);
        end
        $finish;
    end
endmodule
