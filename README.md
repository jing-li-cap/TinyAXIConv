# TinyAXIConv

TinyAXIConv 是一个纯仿真的软硬件协同设计项目：硬件侧实现 AXI-Lite 控制的 3x3 卷积加速器，软件侧通过寄存器映射配置权重、写入 5x5 输入、触发计算并读取 3x3 输出。

这个项目不绑定任何板卡，适合作为 AXI-Lite、寄存器文件、片内 scratchpad、简单流水线数据通路和 Python 驱动协同设计的练习项目。

## 功能概览

- AXI-Lite 从机：AW/W/B/AR/R 五通道握手
- 寄存器映射：控制、状态、kernel、input scratchpad、output scratchpad
- 计算核心：int8 x int8，int32 累加，3x3 valid convolution
- 中断：计算完成后 `irq=1`，读 `STATUS` 后清零
- Python 软件：AXILiteMaster、SimBackend、SerialBackend、ConvAccel
- 验证：3 个 Verilog testbench + 3 个 Python 单元测试

## 地址说明

项目采用 32-bit word-aligned 地址，RTL、testbench 和 Python simulator 使用同一组常量。

| 地址 | 含义 |
| --- | --- |
| `0x000` | 控制寄存器 `CTRL.bit0=start` |
| `0x004` | 状态寄存器 `STATUS.bit0=done`，读后清零 |
| `0x008 + 4*i` | `kernel[i]`, i=0..8，低 8 bit 有效 |
| `0x02C` | 输入基地址寄存器，默认 `0x80` |
| `0x080 + 4*i` | `input[i]`, i=0..24，低 8 bit 有效 |
| `0x100 + 4*i` | `output[i]`, i=0..8，int32 |

原始需求里的若干范围端点与“32-bit 对齐 + 元素数量”有冲突，所以这里采用无重叠的修正版地址。详细说明见 [docs/protocol.md](docs/protocol.md)。

## 目录结构

```text
TinyAXIConv/
  hw/rtl/       # RTL
  hw/sim/       # Verilog testbench
  sw/python/    # Python 模拟后端、驱动、demo、tests
  docs/         # 协议文档和中文教程
```

## 运行 Verilog 仿真

如果已安装 Icarus Verilog：

```powershell
cd TinyAXIConv
New-Item -ItemType Directory -Force build

iverilog -g2012 -o build/tb_axi_lite.vvp hw/rtl/axi_lite_slave.v hw/sim/tb_axi_lite.v
vvp build/tb_axi_lite.vvp

iverilog -g2012 -o build/tb_conv3x3.vvp hw/rtl/conv3x3.v hw/sim/tb_conv3x3.v
vvp build/tb_conv3x3.vvp

iverilog -g2012 -o build/tb_system.vvp hw/rtl/axi_lite_slave.v hw/rtl/reg_ctrl.v hw/rtl/conv3x3.v hw/rtl/top.v hw/sim/tb_system.v
vvp build/tb_system.vvp
```

期望看到：

```text
TB_AXI_LITE PASS
TB_CONV3X3 PASS
TB_SYSTEM PASS
```

## 运行 Python demo 和测试

```powershell
cd TinyAXIConv\sw\python
python demo.py
python -m pytest
```

`demo.py` 会用 Sobel-X 算子处理一个 5x5 图像，并打印 3x3 输出矩阵。若本机安装了 numpy，会与 numpy 结果对比；否则会使用纯 Python reference。

## 设计要点

AXI-Lite 层只负责协议握手，不直接理解卷积寄存器。`reg_ctrl` 把总线访问转换成寄存器读写，并管理 `start/done/irq`。`conv3x3` 只关心启动、输入数组和输出写回端口，所以计算核心与总线协议解耦。

卷积核心使用两级流水线：先乘法，后一拍累加。它复用一个乘法路径完成 9 个 tap，面积小、状态机清楚，适合面试时解释“吞吐率、延迟、面积”的取舍。

Python 的 `SimBackend` 不是随便写的数学函数，而是按 RTL 寄存器行为建模：int8 低 8 bit 写入、读回符号扩展、`STATUS` 读后清零、输出 int32 two's-complement。这保证软件驱动在模拟器和 RTL 之间语义一致。

## 面试常见追问和参考回答

**Q: 为什么使用 AXI-Lite，而不是 AXI4 full 或 AXI-Stream？**  
A: 这个加速器配置量很小，只有权重、输入 scratchpad、控制状态和输出寄存器。AXI-Lite 足够表达 memory-mapped register 访问，协议简单，适合控制路径。AXI4 full 更适合大块 burst 访存，AXI-Stream 更适合连续数据流。

**Q: start 为什么写 1 后自动清零？**  
A: `start` 是命令脉冲，不是状态。软件写 1 表示发起一次计算，硬件产生 `conv_start` 单拍脉冲即可。这样避免软件还要写 0，也避免重复触发。

**Q: done 为什么读后清零？**  
A: 读后清零能把 `STATUS.done` 和 `irq` 绑定成一个简单事件通知机制。软件看到 done 后读状态，即确认并清除中断。真实项目也可以改成 W1C，也就是写 1 清零。

**Q: 为什么输出是 int32？**  
A: 输入和权重都是 int8，单次乘法结果是 int16。3x3 一共 9 项累加，int32 留足范围，也符合很多软件框架对卷积累加器的常见做法。

**Q: 这个两级流水线有什么收益？**  
A: 它把乘法和累加拆成相邻两拍，缩短组合路径，便于提高频率。当前设计复用一个乘法器，吞吐率不是最高，但面积小、控制简单。若追求性能，可以展开 9 个乘法器做并行归约树。

**Q: AXI-Lite 的 AW 和 W 为什么要分别暂存？**  
A: AXI-Lite 允许写地址和写数据通道独立握手，主机不保证两者同拍到达。从机必须能处理 AW-first、W-first 和 simultaneous 三种情况。

**Q: 如果要上板，软件和硬件需要改哪里？**  
A: RTL 顶层要接到 SoC/FPGA 的 AXI-Lite interconnect。Python 侧可以实现 `SerialBackend`，或在嵌入式 C 里按同一寄存器表做 MMIO 读写。`ConvAccel` 这种高层 API 可以保持不变。

**Q: 为什么这里没有 DMA？**  
A: 这是教学版小规模输入，5x5 数据直接放在寄存器 scratchpad 里最直观。更大图像应改成 AXI master + DMA 或 AXI-Stream，让加速器从外部内存/流接口搬运数据。

**Q: 原需求地址范围为什么被修正？**  
A: 32-bit AXI-Lite 常用 4 字节对齐。如果 9 个 kernel、25 个 input、9 个 int32 output 都逐项映射，原范围端点会出现数量不足或重叠。项目选择了无重叠 word-aligned 映射，并在协议文档里逐项列明。
