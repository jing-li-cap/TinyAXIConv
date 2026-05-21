`timescale 1ns/1ps

// ================================================================
// TinyAXIConv 3x3 卷积核心
// ------------------------------------------------
// 功能：
//   - start 拉高后，读取 5x5 input 和 3x3 kernel。
//   - 对 5x5 输入做滑动窗口卷积，产生 3x3 int32 输出。
//   - int8 * int8 的乘法结果扩展到 int32 后累加。
//   - 计算完所有 9 个输出后拉高 done 一个周期。
//
// 两级流水线：
//   第一级：根据当前 output index 和 tap index 取 input/kernel 并做乘法。
//   第二级：把上一拍乘法结果累加到 acc 中。
// ================================================================
module conv3x3 (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  start,
    output reg                   busy,
    output reg                   done,

    input  wire [8*9-1:0]        kernel_flat,
    input  wire [8*25-1:0]       input_flat,

    output reg                   out_we,
    output reg  [3:0]            out_idx,
    output reg  signed [31:0]    out_data
);
    localparam S_IDLE = 1'b0;
    localparam S_RUN  = 1'b1;

    reg state;

    // out_index: 当前正在计算 3x3 输出中的第几个点，范围 0..8。
    // feed_cnt : 第一级已经送入乘法器的 tap 数，范围 0..9。
    // acc_cnt  : 第二级已经累加的乘法结果数，范围 0..8。
    reg [3:0] out_index;
    reg [3:0] feed_cnt;
    reg [3:0] acc_cnt;

    reg signed [15:0] mul_product;
    reg               mul_valid;
    reg signed [31:0] acc;

    wire signed [31:0] product_ext = {{16{mul_product[15]}}, mul_product};
    wire signed [31:0] acc_next    = acc + product_ext;

    // 读取第 idx 个 kernel，idx=0..8。
    function signed [7:0] kernel_at;
        input [3:0] idx;
        begin
            kernel_at = kernel_flat[idx*8 +: 8];
        end
    endfunction

    // 读取当前输出点的第 tap 个输入像素。
    // out_idx 映射到 3x3 输出坐标，tap_idx 映射到 3x3 kernel 坐标。
    function signed [7:0] input_at;
        input [3:0] out_i;
        input [3:0] tap_i;
        integer out_row;
        integer out_col;
        integer ker_row;
        integer ker_col;
        integer in_index;
        begin
            out_row  = out_i / 3;
            out_col  = out_i % 3;
            ker_row  = tap_i / 3;
            ker_col  = tap_i % 3;
            in_index = (out_row + ker_row) * 5 + (out_col + ker_col);
            input_at = input_flat[in_index*8 +: 8];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            out_we      <= 1'b0;
            out_idx     <= 4'd0;
            out_data    <= 32'sd0;
            out_index   <= 4'd0;
            feed_cnt    <= 4'd0;
            acc_cnt     <= 4'd0;
            mul_product <= 16'sd0;
            mul_valid   <= 1'b0;
            acc         <= 32'sd0;
        end else begin
            // out_we/done 都是单周期脉冲。
            out_we <= 1'b0;
            done   <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy      <= 1'b0;
                    mul_valid <= 1'b0;
                    if (start) begin
                        busy      <= 1'b1;
                        state     <= S_RUN;
                        out_index <= 4'd0;
                        feed_cnt  <= 4'd0;
                        acc_cnt   <= 4'd0;
                        acc       <= 32'sd0;
                    end
                end

                S_RUN: begin
                    // ---------------- 第一级：送入一个乘法 tap ----------------
                    if (feed_cnt < 4'd9) begin
                        mul_product <= input_at(out_index, feed_cnt) * kernel_at(feed_cnt);
                        mul_valid   <= 1'b1;
                        feed_cnt    <= feed_cnt + 4'd1;
                    end else begin
                        mul_valid   <= 1'b0;
                    end

                    // ---------------- 第二级：累加上一拍的乘法结果 ------------
                    if (mul_valid) begin
                        if (acc_cnt == 4'd8) begin
                            // 第 9 个 tap 累加完成，本输出点结果有效。
                            out_we   <= 1'b1;
                            out_idx  <= out_index;
                            out_data <= acc_next;

                            mul_valid <= 1'b0;
                            acc       <= 32'sd0;
                            acc_cnt   <= 4'd0;
                            feed_cnt  <= 4'd0;

                            if (out_index == 4'd8) begin
                                // 所有 3x3 输出都写完，done 拉高一个周期。
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= S_IDLE;
                            end else begin
                                out_index <= out_index + 4'd1;
                            end
                        end else begin
                            acc     <= acc_next;
                            acc_cnt <= acc_cnt + 4'd1;
                        end
                    end
                end
            endcase
        end
    end
endmodule
