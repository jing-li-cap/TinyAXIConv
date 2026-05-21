# TinyAXIConv 中文教程

TinyAXIConv 是一个纯仿真的软硬件协同设计项目：软件通过 AXI-Lite 寄存器配置一个 3x3 卷积加速器，硬件从片内 scratchpad 读取 5x5 输入和 3x3 权重，计算 3x3 输出。

## 1. 项目结构

```text
TinyAXIConv/
  hw/rtl/
    axi_lite_slave.v   # AXI-Lite 五通道从机
    reg_ctrl.v         # 寄存器文件、scratchpad、irq/done 管理
    conv3x3.v          # 两级流水 3x3 卷积核心
    top.v              # 顶层连线
  hw/sim/
    tb_axi_lite.v      # AXI-Lite 时序测试
    tb_conv3x3.v       # 卷积核独立测试
    tb_system.v        # AXI-Lite + 寄存器 + 卷积完整系统测试
  sw/python/
    axi_lite.py        # AXILiteMaster、SimBackend、SerialBackend
    conv_driver.py     # ConvAccel 高层驱动
    demo.py            # Sobel 示例
```

## 2. AXI-Lite 从机设计

`axi_lite_slave.v` 把 AXI-Lite 的五个通道转换为内部简单寄存器接口：

- 写：`wr_en/wr_addr/wr_data/wr_strb`
- 读：`rd_en/rd_addr/rd_data`

AXI-Lite 写事务有两个输入通道：AW 传地址，W 传数据。真实系统里这两个通道可能同一拍到，也可能一前一后到。因此模块内部有两个暂存标志：

- `aw_hold_valid`：已经收到写地址但还没等到写数据
- `w_hold_valid`：已经收到写数据但还没等到写地址

当 AW 和 W 都有效时，模块产生一个单周期 `wr_en`，然后返回 `BVALID` 写响应。

读事务更直接：AR 握手时，把地址送到寄存器文件，并在 R 通道返回 `rd_data`。

## 3. 寄存器文件设计

`reg_ctrl.v` 实现三类内容：

1. 控制状态寄存器：`CTRL`、`STATUS`
2. 输入数据：`kernel_mem[0..8]`、`input_mem[0..24]`
3. 输出数据：`output_mem[0..8]`

### start 和 done

软件写 `CTRL.bit0=1` 时，`reg_ctrl` 产生一个单周期 `conv_start` 脉冲。这个脉冲不保存到寄存器，所以读 `CTRL` 恒为 0。

卷积核完成后拉高 `conv_done`，`reg_ctrl` 锁存 `done_latch=1`，同时 `irq=1`。软件读 `STATUS` 后，`done_latch` 被清零，`irq` 也随之清零。

### scratchpad

输入 scratchpad 是 5x5 的 int8 数组，输出 scratchpad 是 3x3 的 int32 数组。这里没有外部内存和 DMA，数据全在寄存器文件内部，方便教学和仿真。

## 4. 卷积核心设计

`conv3x3.v` 做的是 valid convolution：

```text
output[row][col] =
  sum_{kr=0..2, kc=0..2}
    input[row+kr][col+kc] * kernel[kr][kc]
```

输入是 5x5，kernel 是 3x3，因此输出是 3x3。

### 两级流水线

卷积核内部没有一次性例化 9 个乘法器，而是复用一个乘法路径：

- 第一级：读取当前 tap 的 input 和 kernel，计算 int8 x int8
- 第二级：把上一拍乘法结果符号扩展到 int32 后加到累加器

这种结构面积小、逻辑清晰。每个输出点需要 9 次乘法，加上流水线排空，大约 10 拍；9 个输出点总共约 90 拍。

### 写回结果

每算完一个输出点，`conv3x3` 拉高 `out_we` 一个周期，并输出：

- `out_idx`：写回第几个输出元素
- `out_data`：int32 结果

`reg_ctrl` 接收该写回端口，把结果保存到 `output_mem[out_idx]`。

## 5. Python 软件模型

`sw/python/axi_lite.py` 里有三个类：

- `AXILiteMaster`：统一的 `write(addr, data)` / `read(addr)` 接口
- `SimBackend`：纯 Python 模拟硬件寄存器和卷积逻辑
- `SerialBackend`：预留给未来上板时接串口协议

`SimBackend` 与 RTL 保持一致：

- int8 写入只看低 8 bit
- int8 读回做符号扩展
- 写 `CTRL.start` 后运行卷积并置 `done`
- 读 `STATUS` 后清 `done/irq`
- 输出按 int32 two's-complement 保存

`conv_driver.py` 进一步封装成 `ConvAccel`：

- `set_kernel(weights)`
- `set_input(data)`
- `run()`
- `get_output()`

这样应用层不需要关心具体地址。

## 6. Sobel 示例

`demo.py` 使用 Sobel-X 算子：

```text
-1  0  1
-2  0  2
-1  0  1
```

它把 5x5 图像写入模拟后端，运行加速器，然后与 numpy 结果比较。如果本机没有 numpy，脚本会自动使用纯 Python reference convolution。

## 7. 建议实验顺序

1. 先跑 `tb_conv3x3.v`，确认核心算法正确。
2. 再跑 `tb_axi_lite.v`，确认 AW/W/AR/R/B 握手正确。
3. 最后跑 `tb_system.v`，验证完整软硬件寄存器流程。
4. 跑 `python demo.py`，从软件视角理解驱动调用。
5. 跑 `python -m pytest`，确认 Python 模拟器和驱动行为稳定。
