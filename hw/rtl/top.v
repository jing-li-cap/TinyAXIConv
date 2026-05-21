`timescale 1ns/1ps

// ================================================================
// TinyAXIConv 顶层
// ------------------------------------------------
// 连接关系：
//   AXI-Lite Master
//        -> axi_lite_slave
//        -> reg_ctrl
//        -> conv3x3
//   conv3x3 计算完成后写回 reg_ctrl 内的 output scratchpad，并通过 irq 通知软件。
// ================================================================
module top #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // AXI-Lite 写地址通道
    input  wire [ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  wire                     s_axi_awvalid,
    output wire                     s_axi_awready,

    // AXI-Lite 写数据通道
    input  wire [DATA_WIDTH-1:0]    s_axi_wdata,
    input  wire [(DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                     s_axi_wvalid,
    output wire                     s_axi_wready,

    // AXI-Lite 写响应通道
    output wire [1:0]               s_axi_bresp,
    output wire                     s_axi_bvalid,
    input  wire                     s_axi_bready,

    // AXI-Lite 读地址通道
    input  wire [ADDR_WIDTH-1:0]    s_axi_araddr,
    input  wire                     s_axi_arvalid,
    output wire                     s_axi_arready,

    // AXI-Lite 读数据通道
    output wire [DATA_WIDTH-1:0]    s_axi_rdata,
    output wire [1:0]               s_axi_rresp,
    output wire                     s_axi_rvalid,
    input  wire                     s_axi_rready,

    output wire                     irq
);
    wire                     wr_en;
    wire [ADDR_WIDTH-1:0]    wr_addr;
    wire [DATA_WIDTH-1:0]    wr_data;
    wire [(DATA_WIDTH/8)-1:0] wr_strb;
    wire                     rd_en;
    wire [ADDR_WIDTH-1:0]    rd_addr;
    wire [DATA_WIDTH-1:0]    rd_data;

    wire                     conv_start;
    wire                     conv_done;
    wire [8*9-1:0]           kernel_flat;
    wire [8*25-1:0]          input_flat;
    wire                     conv_out_we;
    wire [3:0]               conv_out_idx;
    wire signed [31:0]       conv_out_data;
    wire                     conv_busy;

    axi_lite_slave #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_axi_lite_slave (
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

    reg_ctrl #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_reg_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .wr_strb(wr_strb),
        .rd_en(rd_en),
        .rd_addr(rd_addr),
        .rd_data(rd_data),
        .conv_start(conv_start),
        .conv_done(conv_done),
        .conv_out_we(conv_out_we),
        .conv_out_idx(conv_out_idx),
        .conv_out_data(conv_out_data),
        .kernel_flat(kernel_flat),
        .input_flat(input_flat),
        .irq(irq)
    );

    conv3x3 u_conv3x3 (
        .clk(clk),
        .rst_n(rst_n),
        .start(conv_start),
        .busy(conv_busy),
        .done(conv_done),
        .kernel_flat(kernel_flat),
        .input_flat(input_flat),
        .out_we(conv_out_we),
        .out_idx(conv_out_idx),
        .out_data(conv_out_data)
    );
endmodule
