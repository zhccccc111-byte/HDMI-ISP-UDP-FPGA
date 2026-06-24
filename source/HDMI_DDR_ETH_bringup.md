# HDMI DDR Ethernet 上板联调说明

## 1. 当前生成结果

- 顶层模块：`hdmi_ddr_eth_top`
- 最新时序报告：`D:\WorkSpace\HDMI_IN_ISP_SCALE\HDMI_IN_ISP_SCALE\HDMI_IN_DDR3_isp_640_rx\place_route\hdmi_ddr_eth_top_timing_summary_after_hold_fix.txt`
- 最新下载文件：`D:\WorkSpace\HDMI_IN_ISP_SCALE\HDMI_IN_ISP_SCALE\HDMI_IN_DDR3_isp_640_rx\generate_bitstream\hdmi_ddr_eth_top.sbit`
- 当前状态：`All Constraints Met`

## 2. 当前默认网络参数

来自 `hdmi_ddr_eth_top.v` 的默认参数如下：

- 图像宽度：`640`
- 图像高度：`360`
- 发送节拍：`OUTPUT_FRAME_PERIOD_CNT = 8_333_333`
- 本地 IP：`192.168.1.11`
- 本地端口：`8080`
- 目标 IP：`192.168.1.105`
- 目标端口：`8080`
- 目标 MAC：`9A-CB-4C-37-BF-04`
- 目标 MAC 模式：`FIXED_DEST_MAC_EN = 1`

注意：

- 当前工程默认使用固定目标 MAC。
- 如果你的接收端网卡 MAC 不是 `9A-CB-4C-37-BF-04`，即使 IP 对了，也可能收不到数据。
- 上板前建议二选一：
  - 直接把顶层里的 `DEST_MAC` 改成你的 PC 网卡 MAC
  - 或者后续把 `FIXED_DEST_MAC_EN` 改为 `0`，走 ARP 自动解析

## 3. UDP 数据格式

当前设计中：

- 每个 UDP 包对应一行图像
- 每包长度：`6 + 640 * 2 = 1286` 字节

字节格式：

- `byte[0..3]`：`frame_id`，大端
- `byte[4..5]`：`line_id`
- `byte[6..1285]`：`640` 个 `RGB565` 像素，高字节在前

行号范围：

- `line_id = 0..359`

## 4. 板上期望现象

下载成功后，正常情况下应当依次出现：

1. DDR 初始化完成
2. HDMI 接收芯片初始化完成
3. PHY 复位释放
4. HDMI 输入有效后，处理后图像开始写入 DDR
5. 至少写完一帧后，网口开始持续发 UDP 行包

建议重点观察这些信号：

- `ddr_init_done`
- `init_over_rx`
- `heart_beat_led`
- `phy_rstn`
- `rgmii_txc`
- `rgmii_tx_ctl`

## 5. debug_status 调试总线

当前顶层已经加入：

- `debug_status[7:0]`

它复用了原来不再使用的显示输出引脚。

位定义如下：

- `debug_status[0]`：处理后图像一帧写入 DDR 完成时翻转一次
- `debug_status[1]`：一帧被 DDR 读出并送往以太网完成时翻转一次
- `debug_status[2]`：UDP 发送活动指示
- `debug_status[3]`：当前 `direct_line_valid`
- `debug_status[7:4]`：当前行号桶，等于 `line_id[8:5]`

推荐理解方式：

- `debug_status[0]` 不变：说明 HDMI 输入、ISP 或 DDR 写路径没有形成完整帧
- `debug_status[0]` 在变、`debug_status[1]` 不变：说明写入有了，但 DDR 读链没有完整消费
- `debug_status[1]` 在变、`debug_status[2]` 不亮：说明读链有数据，但 UDP 发包还没真正起来
- `debug_status[7:4]` 在变化：说明当前发送行号在推进

## 6. 最小联调方法

### 方案 A：FPGA 直连 PC

1. 把 PC 网卡 IP 设成 `192.168.1.105`
2. 如果保持固定 MAC 模式，把工程里的 `DEST_MAC` 改成这张网卡的真实 MAC
3. FPGA 和 PC 网口直连
4. 给板子输入稳定 HDMI 视频
5. 在 PC 端运行 UDP 接收脚本

### 方案 B：通过交换机

1. FPGA 和 PC 放在同一网段
2. PC 设置为 `192.168.1.105`
3. 如果交换机环境复杂，优先建议后续切到 ARP 模式

## 7. PC 端接收脚本

当前工程已提供：

- `D:\WorkSpace\HDMI_IN_ISP_SCALE\HDMI_IN_ISP_SCALE\HDMI_IN_DDR3_isp_640_rx\source\tools\udp_frame_dump.py`

示例命令：

```powershell
python .\source\tools\udp_frame_dump.py --bind-ip 0.0.0.0 --port 8080 --width 640 --height 360 --output-dir .\captures
```

脚本功能：

- 接收 FPGA 发来的 UDP 行包
- 按 `frame_id + line_id` 重组一整帧
- 把 `RGB565` 转成 `RGB888`
- 每帧保存成 `.ppm`

## 8. Wireshark 检查方法

过滤条件：

```text
udp.port == 8080
```

重点检查：

- 源 IP 是否为 `192.168.1.11`
- 目标 IP 是否为 `192.168.1.105`
- UDP 负载长度是否为 `1286`
- `line_id` 是否从 `0` 连续到 `359`

## 9. 如果没有收到包

按下面顺序排查：

1. `phy_rstn` 是否已经拉高
2. `rgmii_txc` 是否在跳变
3. `ddr_init_done` 是否为高
4. `init_over_rx` 是否为高
5. HDMI 输入是否真的有效
6. 固定 MAC 模式下，`DEST_MAC` 是否和接收端网卡一致
7. PC 防火墙是否拦截了 `8080` 端口 UDP

## 10. 如果收到了包但图像异常

优先检查：

1. 接收端是否按 `RGB565` 高字节在前解析
2. 接收端是否按 `640x360` 而不是 `640x640` 重组
3. `line_id` 是否有跳变、重复或缺失
4. 是否出现读到未完成帧的情况
5. `debug_status[0]` 和 `debug_status[1]` 的翻转节奏是否异常

## 11. 当前建议的下一步

如果你准备继续往实用化推进，最值得做的是：

1. 把固定目标 MAC 改成 ARP 自动解析
2. 给 `debug_status` 再配一份更直观的板级说明
3. 如果还需要更稳的联调，再增加少量 DDR 读写状态输出
