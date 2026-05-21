`timescale 1ns/1ps

// ================================================================
// TinyAXIConv 寄存器文件与 scratchpad
// ------------------------------------------------
// 地址映射采用 32-bit word-aligned 方式，便于 AXI-Lite 主机访问：
//   0x000        控制寄存器，bit0=start，写 1 产生 conv_start 单拍脉冲
//   0x004        状态寄存器，bit0=done，只读，读后清零
//   0x008-0x028  kernel[0..8]，每个寄存器低 8 bit 为 int8 权重
//   0x02C        输入数据基地址寄存器，默认值 0x80，仿真中仅作可读配置项
//   0x080-0x0E0  input[0..24]，每个寄存器低 8 bit 为 int8 像素
//   0x100-0x120  output[0..8]，每个寄存器为 int32 卷积结果
//
// 注：用户原始地址表中的若干范围端点与“32-bit 对齐 + 元素数量”不完全一致。
// 本实现选择唯一且无重叠的对齐地址，并在文档中逐项列出。
// ================================================================
module reg_ctrl #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // 来自 axi_lite_slave 的内部写端口
    input  wire                     wr_en,
    input  wire [ADDR_WIDTH-1:0]    wr_addr,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    input  wire [(DATA_WIDTH/8)-1:0] wr_strb,

    // 来自 axi_lite_slave 的内部读端口
    input  wire                     rd_en,
    input  wire [ADDR_WIDTH-1:0]    rd_addr,
    output reg  [DATA_WIDTH-1:0]    rd_data,

    // 与卷积核心的控制/状态连接
    output reg                      conv_start,
    input  wire                     conv_done,

    // 卷积核心写回输出 scratchpad 的端口
    input  wire                     conv_out_we,
    input  wire [3:0]               conv_out_idx,
    input  wire signed [31:0]       conv_out_data,

    // 以打包总线形式把 kernel 和 input 暴露给 conv3x3
    output wire [8*9-1:0]           kernel_flat,
    output wire [8*25-1:0]          input_flat,

    // 中断信号：done 锁存为 1 时拉高，读状态寄存器后清零
    output wire                     irq
);
    localparam [ADDR_WIDTH-1:0] ADDR_CTRL       = 12'h000;
    localparam [ADDR_WIDTH-1:0] ADDR_STATUS     = 12'h004;
    localparam [ADDR_WIDTH-1:0] ADDR_KERNEL     = 12'h008;
    localparam [ADDR_WIDTH-1:0] ADDR_INPUT_BASE = 12'h02C;
    localparam [ADDR_WIDTH-1:0] ADDR_INPUT      = 12'h080;
    localparam [ADDR_WIDTH-1:0] ADDR_OUTPUT     = 12'h100;

    integer i;
    integer rd_index;
    integer wr_index;

    // kernel_mem/input_mem 是 int8，output_mem 是 int32。
    reg signed [7:0]  kernel_mem [0:8];
    reg signed [7:0]  input_mem  [0:24];
    reg signed [31:0] output_mem [0:8];

    reg [31:0] input_base_reg;
    reg        done_latch;

    assign irq = done_latch;

    // 将数组打包成扁平总线，conv3x3 用固定下标读取。
    genvar k;
    generate
        for (k = 0; k < 9; k = k + 1) begin : PACK_KERNEL
            assign kernel_flat[k*8 +: 8] = kernel_mem[k];
        end
    endgenerate

    genvar p;
    generate
        for (p = 0; p < 25; p = p + 1) begin : PACK_INPUT
            assign input_flat[p*8 +: 8] = input_mem[p];
        end
    endgenerate

    // 按字节写使能更新 32-bit 寄存器的通用函数。
    function [31:0] apply_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0]  byte_en;
        integer      b;
        begin
            apply_wstrb = old_value;
            for (b = 0; b < 4; b = b + 1) begin
                if (byte_en[b]) begin
                    apply_wstrb[b*8 +: 8] = new_value[b*8 +: 8];
                end
            end
        end
    endfunction

    // 符号扩展 int8，方便软件读回 kernel/input 时看到有符号值。
    function [31:0] sign_extend_i8;
        input signed [7:0] value;
        begin
            sign_extend_i8 = {{24{value[7]}}, value};
        end
    endfunction

    // 组合读路径：AXI-Lite 读地址握手时，axi_lite_slave 会立即采样 rd_data。
    always @(*) begin
        rd_data = 32'h0000_0000;

        if (rd_addr == ADDR_CTRL) begin
            // start 为写 1 触发、自清零信号，因此读控制寄存器恒为 0。
            rd_data = 32'h0000_0000;
        end else if (rd_addr == ADDR_STATUS) begin
            rd_data = {31'b0, done_latch};
        end else if (rd_addr == ADDR_INPUT_BASE) begin
            rd_data = input_base_reg;
        end else if ((rd_addr >= ADDR_KERNEL) &&
                     (rd_addr <  ADDR_KERNEL + 9*4) &&
                     (rd_addr[1:0] == 2'b00)) begin
            rd_index = (rd_addr - ADDR_KERNEL) >> 2;
            rd_data = sign_extend_i8(kernel_mem[rd_index]);
        end else if ((rd_addr >= ADDR_INPUT) &&
                     (rd_addr <  ADDR_INPUT + 25*4) &&
                     (rd_addr[1:0] == 2'b00)) begin
            rd_index = (rd_addr - ADDR_INPUT) >> 2;
            rd_data = sign_extend_i8(input_mem[rd_index]);
        end else if ((rd_addr >= ADDR_OUTPUT) &&
                     (rd_addr <  ADDR_OUTPUT + 9*4) &&
                     (rd_addr[1:0] == 2'b00)) begin
            rd_index = (rd_addr - ADDR_OUTPUT) >> 2;
            rd_data = output_mem[rd_index];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            conv_start     <= 1'b0;
            done_latch     <= 1'b0;
            input_base_reg <= 32'h0000_0080;

            for (i = 0; i < 9; i = i + 1) begin
                kernel_mem[i] <= 8'sd0;
                output_mem[i] <= 32'sd0;
            end
            for (i = 0; i < 25; i = i + 1) begin
                input_mem[i] <= 8'sd0;
            end
        end else begin
            // conv_start 是单周期脉冲，每拍默认拉低。
            conv_start <= 1'b0;

            // 软件读状态寄存器后清 done 和 irq。
            if (rd_en && (rd_addr == ADDR_STATUS)) begin
                done_latch <= 1'b0;
            end

            // 卷积完成后锁存 done；如果同拍发生读清零，完成事件优先，避免丢中断。
            if (conv_done) begin
                done_latch <= 1'b1;
            end

            // 卷积核心逐项写回 3x3 输出结果。
            if (conv_out_we && (conv_out_idx < 9)) begin
                output_mem[conv_out_idx] <= conv_out_data;
            end

            if (wr_en) begin
                if (wr_addr == ADDR_CTRL) begin
                    // 只关注 bit0=start。写 1 触发，硬件不保存该位。
                    if (wr_strb[0] && wr_data[0]) begin
                        conv_start <= 1'b1;
                    end
                end else if (wr_addr == ADDR_INPUT_BASE) begin
                    input_base_reg <= apply_wstrb(input_base_reg, wr_data, wr_strb);
                end else if ((wr_addr >= ADDR_KERNEL) &&
                             (wr_addr <  ADDR_KERNEL + 9*4) &&
                             (wr_addr[1:0] == 2'b00)) begin
                    wr_index = (wr_addr - ADDR_KERNEL) >> 2;
                    if (wr_strb[0]) begin
                        kernel_mem[wr_index] <= wr_data[7:0];
                    end
                end else if ((wr_addr >= ADDR_INPUT) &&
                             (wr_addr <  ADDR_INPUT + 25*4) &&
                             (wr_addr[1:0] == 2'b00)) begin
                    wr_index = (wr_addr - ADDR_INPUT) >> 2;
                    if (wr_strb[0]) begin
                        input_mem[wr_index] <= wr_data[7:0];
                    end
                end
            end
        end
    end
endmodule
