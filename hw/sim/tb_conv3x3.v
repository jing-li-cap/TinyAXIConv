`timescale 1ns/1ps

// ================================================================
// tb_conv3x3
// ------------------------------------------------
// 输入 5x5 全 1，kernel 3x3 全 1。
// 每个 3x3 窗口累加 9 个 1*1，因此 9 个输出都应为 9。
// ================================================================
module tb_conv3x3;
    reg clk;
    reg rst_n;
    reg start;
    wire busy;
    wire done;
    reg  [8*9-1:0]  kernel_flat;
    reg  [8*25-1:0] input_flat;
    wire out_we;
    wire [3:0] out_idx;
    wire signed [31:0] out_data;

    reg signed [31:0] output_mem [0:8];
    integer i;
    integer errors;

    conv3x3 dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .kernel_flat(kernel_flat),
        .input_flat(input_flat),
        .out_we(out_we),
        .out_idx(out_idx),
        .out_data(out_data)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (out_we) begin
            output_mem[out_idx] <= out_data;
            $display("[%0t] CONV WRITE output[%0d] = %0d", $time, out_idx, out_data);
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        kernel_flat = {8*9{1'b0}};
        input_flat  = {8*25{1'b0}};
        errors = 0;

        for (i = 0; i < 9; i = i + 1) begin
            output_mem[i] = 32'sd0;
        end

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        $display("[%0t] RESET done", $time);

        for (i = 0; i < 9; i = i + 1) begin
            kernel_flat[i*8 +: 8] = 8'sd1;
            $display("kernel[%0d] = 1", i);
        end
        for (i = 0; i < 25; i = i + 1) begin
            input_flat[i*8 +: 8] = 8'sd1;
            $display("input[%0d] = 1", i);
        end

        @(posedge clk);
        start <= 1'b1;
        $display("[%0t] START convolution", $time);
        @(posedge clk);
        start <= 1'b0;

        wait (done);
        $display("[%0t] DONE observed", $time);
        repeat (2) @(posedge clk);

        for (i = 0; i < 9; i = i + 1) begin
            if (output_mem[i] !== 32'sd9) begin
                $display("  FAIL output[%0d]: got=%0d expected=9", i, output_mem[i]);
                errors = errors + 1;
            end else begin
                $display("  PASS output[%0d] = 9", i);
            end
        end

        if (errors == 0) begin
            $display("TB_CONV3X3 PASS");
        end else begin
            $display("TB_CONV3X3 FAIL errors=%0d", errors);
        end
        $finish;
    end
endmodule
