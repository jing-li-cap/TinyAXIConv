# TinyAXIConv Protocol

本文档说明 TinyAXIConv 的 AXI-Lite 寄存器协议、地址映射和读写时序。

## 地址映射

TinyAXIConv 使用 32-bit AXI-Lite 数据总线。为避免数组元素重叠，所有寄存器按 4 字节对齐。

> 说明：原始需求中 `kernel[0..8]`、`input[0..24]`、`output[0..8]` 的范围端点与 32-bit 对齐访问存在冲突。本项目采用下表这组无重叠地址，RTL、testbench 和 Python simulator 完全一致。

| 地址 | 名称 | 访问 | 位定义 |
| --- | --- | --- | --- |
| `0x000` | `CTRL` | W/R | bit0=`start`，写 1 触发，硬件自动清零；读恒为 0 |
| `0x004` | `STATUS` | R | bit0=`done`，计算完成置 1，读后清零 |
| `0x008 + 4*i` | `KERNEL[i]`, i=0..8 | W/R | bit[7:0] 为有符号 int8，读回时符号扩展到 32 bit |
| `0x02C` | `INPUT_BASE_REG` | W/R | 默认 `0x80`，纯仿真中仅作为说明性配置项 |
| `0x080 + 4*i` | `INPUT[i]`, i=0..24 | W/R | bit[7:0] 为有符号 int8，读回时符号扩展到 32 bit |
| `0x100 + 4*i` | `OUTPUT[i]`, i=0..8 | R | 有符号 int32 卷积结果 |

数组展开顺序均为 row-major：

- `KERNEL[0..8]` 对应 3x3 kernel：`row * 3 + col`
- `INPUT[0..24]` 对应 5x5 输入：`row * 5 + col`
- `OUTPUT[0..8]` 对应 3x3 输出：`row * 3 + col`

## 控制流程

典型软件流程如下：

1. 写 `KERNEL[0..8]`，每个值使用 int8 范围 `[-128, 127]`。
2. 写 `INPUT[0..24]`，每个值使用 int8 范围 `[-128, 127]`。
3. 写 `CTRL.bit0=1` 触发计算。
4. 等待 `irq=1`，或轮询 `STATUS.bit0`。
5. 读 `STATUS` 清除 `done/irq`。
6. 读 `OUTPUT[0..8]` 获取 9 个 int32 结果。

## AXI-Lite 写时序

AXI-Lite 写事务包含 AW、W、B 三个通道。

- AW 通道传输写地址：`AWADDR/AWVALID/AWREADY`
- W 通道传输写数据：`WDATA/WSTRB/WVALID/WREADY`
- B 通道返回写响应：`BRESP/BVALID/BREADY`

`axi_lite_slave.v` 支持 AW 和 W 任意先后到达：

```text
Master: AWVALID=1, AWADDR=addr
Slave : AWREADY=1 后锁存地址

Master: WVALID=1, WDATA=data, WSTRB=4'hF
Slave : WREADY=1 后锁存数据

Slave : AW/W 都收到后，内部 wr_en 拉高 1 拍
Slave : BVALID=1, BRESP=OKAY
Master: BREADY=1 后写事务结束
```

本项目默认 `BRESP=2'b00`，即 OKAY。

## AXI-Lite 读时序

AXI-Lite 读事务包含 AR、R 两个通道。

- AR 通道传输读地址：`ARADDR/ARVALID/ARREADY`
- R 通道返回读数据：`RDATA/RRESP/RVALID/RREADY`

```text
Master: ARVALID=1, ARADDR=addr
Slave : ARREADY=1 后，内部 rd_en 拉高 1 拍
Slave : 下一拍 RVALID=1, RDATA=寄存器读值, RRESP=OKAY
Master: RREADY=1 后读事务结束
```

读 `STATUS` 时，`RDATA.bit0` 返回清零前的 done 值；同一读事务会清除 done latch 和 irq。

## 数据格式

### int8 写入

写 `KERNEL` 或 `INPUT` 时，RTL 只使用 `WDATA[7:0]`：

- 写 `1`：`WDATA=0x00000001`
- 写 `-1`：`WDATA=0x000000FF`
- 写 `-128`：`WDATA=0x00000080`

读回 int8 寄存器时，RTL 会符号扩展：

- `0xFF` 读回 `0xFFFFFFFF`
- `0x80` 读回 `0xFFFFFF80`

### int32 输出

`OUTPUT` 是完整 int32 two's-complement 值。Python 驱动用 `to_s32()` 把 32-bit bus value 转回 Python signed int。
