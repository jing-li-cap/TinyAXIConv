`timescale 1ns/1ps

// ================================================================
// TinyAXIConv AXI-Lite 从机接口
// ------------------------------------------------
// 作用：
//   1. 实现 AXI-Lite 五个通道：AW/W/B/AR/R。
//   2. 将总线事务转换成内部寄存器文件更容易使用的单周期读写脉冲。
//   3. 读写响应均返回 OKAY，本项目不建模 SLVERR/DECERR。
//
// 说明：
//   - AW 和 W 通道允许先后到达，模块会分别暂存地址和数据。
//   - 内部 wr_en 在 AW/W 都握手完成的那个时钟边沿有效。
//   - 内部 rd_en 在 AR 握手的那个时钟边沿有效，R 数据随后有效。
// ================================================================
module axi_lite_slave #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // ---------------- AXI-Lite 写地址通道 AW ----------------
    input  wire [ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  wire                     s_axi_awvalid,
    output wire                     s_axi_awready,

    // ---------------- AXI-Lite 写数据通道 W -----------------
    input  wire [DATA_WIDTH-1:0]    s_axi_wdata,
    input  wire [(DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                     s_axi_wvalid,
    output wire                     s_axi_wready,

    // ---------------- AXI-Lite 写响应通道 B -----------------
    output reg  [1:0]               s_axi_bresp,
    output reg                      s_axi_bvalid,
    input  wire                     s_axi_bready,

    // ---------------- AXI-Lite 读地址通道 AR ----------------
    input  wire [ADDR_WIDTH-1:0]    s_axi_araddr,
    input  wire                     s_axi_arvalid,
    output wire                     s_axi_arready,

    // ---------------- AXI-Lite 读数据通道 R -----------------
    output reg  [DATA_WIDTH-1:0]    s_axi_rdata,
    output reg  [1:0]               s_axi_rresp,
    output reg                      s_axi_rvalid,
    input  wire                     s_axi_rready,

    // ---------------- 内部寄存器写接口 ----------------------
    output wire                     wr_en,
    output wire [ADDR_WIDTH-1:0]    wr_addr,
    output wire [DATA_WIDTH-1:0]    wr_data,
    output wire [(DATA_WIDTH/8)-1:0] wr_strb,

    // ---------------- 内部寄存器读接口 ----------------------
    output wire                     rd_en,
    output wire [ADDR_WIDTH-1:0]    rd_addr,
    input  wire [DATA_WIDTH-1:0]    rd_data
);
    localparam [1:0] RESP_OKAY = 2'b00;

    // AW/W 可以独立握手，因此分别保存“已经收到但还没组成完整写事务”的内容。
    reg                      aw_hold_valid;
    reg  [ADDR_WIDTH-1:0]    aw_hold_addr;
    reg                      w_hold_valid;
    reg  [DATA_WIDTH-1:0]    w_hold_data;
    reg  [(DATA_WIDTH/8)-1:0] w_hold_strb;

    // 当写响应尚未被主机接收时，暂停接收新的写事务，保持模型简单清晰。
    assign s_axi_awready = (!aw_hold_valid) && (!s_axi_bvalid);
    assign s_axi_wready  = (!w_hold_valid)  && (!s_axi_bvalid);

    wire aw_fire = s_axi_awvalid && s_axi_awready;
    wire w_fire  = s_axi_wvalid  && s_axi_wready;

    wire have_aw = aw_hold_valid || aw_fire;
    wire have_w  = w_hold_valid  || w_fire;

    // 当前写事务的有效地址/数据：可能来自暂存寄存器，也可能来自本周期握手。
    wire [ADDR_WIDTH-1:0]     write_addr_mux = aw_fire ? s_axi_awaddr : aw_hold_addr;
    wire [DATA_WIDTH-1:0]     write_data_mux = w_fire  ? s_axi_wdata  : w_hold_data;
    wire [(DATA_WIDTH/8)-1:0] write_strb_mux = w_fire  ? s_axi_wstrb  : w_hold_strb;

    wire write_fire = have_aw && have_w && (!s_axi_bvalid);

    assign wr_en   = write_fire;
    assign wr_addr = write_addr_mux;
    assign wr_data = write_data_mux;
    assign wr_strb = write_fire ? write_strb_mux : {(DATA_WIDTH/8){1'b0}};

    // 读通道不需要额外暂存：AR 握手时立即访问内部寄存器文件，
    // 下一拍主机即可看到 RVALID 和 RDATA。
    assign s_axi_arready = !s_axi_rvalid;
    wire ar_fire = s_axi_arvalid && s_axi_arready;
    assign rd_en   = ar_fire;
    assign rd_addr = s_axi_araddr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_hold_valid <= 1'b0;
            aw_hold_addr  <= {ADDR_WIDTH{1'b0}};
            w_hold_valid  <= 1'b0;
            w_hold_data   <= {DATA_WIDTH{1'b0}};
            w_hold_strb   <= {(DATA_WIDTH/8){1'b0}};
            s_axi_bresp   <= RESP_OKAY;
            s_axi_bvalid  <= 1'b0;
            s_axi_rdata   <= {DATA_WIDTH{1'b0}};
            s_axi_rresp   <= RESP_OKAY;
            s_axi_rvalid  <= 1'b0;
        end else begin
            // 暂存先到达的 AW 或 W；如果本周期组成完整事务，则不再保留。
            if (write_fire) begin
                aw_hold_valid <= 1'b0;
                w_hold_valid  <= 1'b0;
            end else begin
                if (aw_fire) begin
                    aw_hold_valid <= 1'b1;
                    aw_hold_addr  <= s_axi_awaddr;
                end
                if (w_fire) begin
                    w_hold_valid <= 1'b1;
                    w_hold_data  <= s_axi_wdata;
                    w_hold_strb  <= s_axi_wstrb;
                end
            end

            // 写事务完成后返回 OKAY 响应，等待主机 BREADY 接收。
            if (write_fire) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= RESP_OKAY;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            // 读地址握手后锁存内部寄存器数据，并给出 OKAY 响应。
            if (ar_fire) begin
                s_axi_rdata  <= rd_data;
                s_axi_rresp  <= RESP_OKAY;
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end
endmodule
