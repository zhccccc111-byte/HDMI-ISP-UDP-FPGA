# HDMI 输入 + DDR + 以太网整合流程

## 1. 目标

最终工程目标：

```text
HDMI 输入
  -> ISP / 缩放 / RGB565
  -> 写入 DDR
  -> 从 DDR 读取处理后图像
  -> 通过以太网 UDP 发出
```

本版本不需要显示输出。

## 2. 整合原则

1. 以当前 HDMI 工程为主工程。
2. 只保留一套 DDR 控制器。
3. HDMI 输入和 ISP 处理链保留当前工程。
4. 以太网发送链移植进当前工程。
5. 当前工程负责写 DDR。
6. 以太网读链负责从 DDR 读数据并发包。
7. 显示链全部删除或停用。

## 3. 当前整合后的结构

当前工程已经形成如下主结构：

```text
hdmi_ddr_eth_top
├─ HDMI 输入与 MS72xx 配置
├─ ISP 处理链
│  ├─ gamma_lookuptable
│  ├─ rgb_gauss
│  ├─ isp_csc
│  ├─ isp_ee
│  ├─ isp_occ
│  └─ scale3x_downsampler
├─ DDR 写链
│  └─ ddr_frame_writer_only
├─ DDR 读链
│  ├─ ddr_play_reader
│  └─ ddr_play_line_bridge
├─ 以太网发送链
│  ├─ eth_udp_test
│  ├─ udp/ip/mac/arp
│  └─ rgmii_interface
└─ DDR 控制器
   └─ ddr3_test
```

## 4. 已经完成的关键工作

### 4.1 源码并入

以太网相关源码已经并入当前工程：

- 目录：`source\eth`

其中包括：

- `ddr_play_reader.v`
- `ddr_play_line_bridge.v`
- `eth_udp_test.v`
- `rgmii_interface.v`
- `pll_phase.v`
- `ref_clock.v`
- `udp/ip/mac/arp` 相关模块

### 4.2 新增辅助模块

已新增：

- `source\rtl\hdmi_ddr_eth_top.v`
- `source\rtl\ddr_frame_writer_only.v`
- `source\rtl\play_rst_sync.v`

### 4.3 工程文件更新

已更新：

- `HDMI_IN_DDR3_gamma.pds`
- `HDMI_IN_DDR3_gamma_top.fdc`

并且已经完成：

- `compile`
- `device_map`
- `pnr`
- `gen_bit_stream`

### 4.4 时序闭合

当前最新实现已经达到：

- `All Constraints Met`

关键是补了：

- `pixclk_in` 显式时钟约束
- `sys_clk / ddr / rgmii / pixclk_in` 时钟组关系

### 4.5 ISP 锐化模块重构

为了收敛 `pixclk_in` 域时序，已经把：

- `isp_ee.v`

从原来的“大数组逐拍移位”实现，重构为：

- `matrix_3x3 + fifo_line_buf`

这一改动是时序闭合的关键。

## 5. 当前默认参数

当前默认图像与网络参数：

- `IMG_WIDTH = 640`
- `IMG_HEIGHT = 360`
- `LOCAL_IP = 192.168.1.11`
- `LOCAL_PORT = 8080`
- `DEST_IP = 192.168.1.105`
- `DEST_PORT = 8080`
- `FIXED_DEST_MAC_EN = 1`

## 6. DDR 读写关系

### 6.1 写侧

写侧由：

- `ddr_frame_writer_only`

负责把处理后的 `RGB565` 写入 DDR。

### 6.2 读侧

读侧由：

- `ddr_play_reader`
- `ddr_play_line_bridge`

负责从 DDR 读取完整帧，再按行送给以太网发送链。

### 6.3 帧同步策略

当前已实现：

- 写侧帧完成时，`frame_wirq` 触发
- 顶层更新 `latest_frame_valid / latest_frame_id / latest_frame_slot`
- 读侧 `ddr_play_reader` 只在安全边界切换到最新完整帧

也就是说，现在不是盲目轮转读帧，而是跟随“最近一帧已经写完”的帧缓冲。

## 7. debug_status 调试总线

当前顶层已新增：

- `debug_status[7:0]`

位定义：

- `bit0`：帧写完成翻转
- `bit1`：帧读完成翻转
- `bit2`：UDP 活动
- `bit3`：`direct_line_valid`
- `bit7:4`：行号桶

这组信号已经绑到原显示输出引脚上，方便上板直接观察。

## 8. 产物文件

最新下载文件：

- `generate_bitstream\hdmi_ddr_eth_top.sbit`

最新时序文件：

- `place_route\hdmi_ddr_eth_top_timing_summary_after_hold_fix.txt`

## 9. 当前仍然建议注意的点

### 9.1 目标 MAC 仍是固定模式

当前默认：

- `FIXED_DEST_MAC_EN = 1`

如果目标 MAC 不对，PC 会收不到 UDP。

### 9.2 板级配置项 SCBV

生成 bitstream 时仍提示：

- `SCBV has not been set`

这不影响当前 bitstream 生成，但正式上板前最好按板卡配置再确认。

### 9.3 仍有一些非关键端口未做严格 IO 时序约束

当前内部时序已经闭合，但板级接口如果以后要做更严格签核，仍可以继续补：

- 输入输出延时
- 更精细的 RGMII/HDMI 板级约束

## 10. 当前最推荐的下一步

接下来最值得做的是：

1. 先按 `HDMI_DDR_ETH_bringup.md` 上板验证
2. 确认 `debug_status` 节奏是否正常
3. 用 PC 端脚本抓 UDP 数据并重组图像
4. 若确认链路稳定，再考虑把固定 MAC 模式改成 ARP 模式
