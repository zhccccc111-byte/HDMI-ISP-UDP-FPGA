# RK 端车牌识别接收器

运行在 Rockchip RK3588 等 NPU 平台上的车牌识别接收端程序，与 FPGA 端 HDMI-ISP-UDP 推流系统配合使用。

## 功能

1. 接收 FPGA 通过以太网发来的 UDP 图像帧（640x640 RGB565）
2. 重组完整帧，缺失行自动补线
3. 使用 FastestDet 模型进行车牌检测（352x352 输入）
4. 使用 CRNN 模型进行车牌文字识别（168x48 输入）
5. X11 窗口实时显示检测框和识别结果

## 数据流

```
UDP 接收 (640x640 RGB565, 每包一行)
  -> 帧重组 + 补线
  -> 最近邻缩放到 352x352 (RGB)
  -> FastestDet 车牌检测 (RKNN NPU)
  -> NMS 后处理
  -> 裁剪车牌 ROI
  -> 双层车牌拼接处理
  -> 缩放到 168x48 (BGR)
  -> CRNN 车牌识别 (RKNN NPU)
  -> CTC 解码
  -> X11 叠加显示
```

## 多线程架构

```
read_thread:     UDP 接收 + 帧重组 + RGB565->RGB 预处理
detect_thread:   FastestDet NPU 推理
rec_thread:      检测后处理 + 裁剪 + 识别推理 + 解码
main_thread:     X11 显示 + 事件处理
```

线程间通过 `LatestQueue`（最新帧优先队列）连接，旧帧自动丢弃。

## 依赖

- RKNN SDK 2.x（需设置 `RKNN_API_ROOT`）
- OpenCV 4.x
- X11 + XShm
- C++17 编译器

## 编译

```bash
mkdir build && cd build
cmake .. -DRKNN_API_ROOT=/path/to/rknn-sdk
make -j$(nproc)
```

## 运行

```bash
./main_v5_cpp -p 8080 -S 2
```

### 命令行参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `-b, --bind-ip IP` | 绑定 IP | 0.0.0.0 |
| `-p, --port PORT` | UDP 端口 | 8080 |
| `-s, --source-ip IP` | 仅接受指定源 IP 的包 | 无 |
| `-r, --source-port PORT` | 仅接受指定源端口的包 | 无 |
| `-B, --rcvbuf-mb N` | Socket 接收缓冲区 (MB) | 32 |
| `-S, --scale N` | X11 窗口整数放大倍数 | 1 |
| `-i, --interval SEC` | 调试报告间隔 (秒) | 1.0 |
| `-t, --title TEXT` | X11 窗口标题 | RKNN Plate UDP Debug |

## 模型文件

- `FastestDet.rknn` — 车牌检测模型（FastestDet, 352x352 输入, 2 类: 单层/双层车牌）
- `best.rknn` — 车牌识别模型（CRNN, 168x48 输入, 80 类字符）

## 与 FPGA 端对接

FPGA 默认目标 IP 为 `192.168.1.105`，端口 `8080`。确保：

1. RK 板网口 IP 设为 `192.168.1.105`
2. FPGA 发出的 UDP 包格式：`frame_id(4B) + line_id(2B) + 640×RGB565(1280B)` = 1286 字节/包
3. 运行时加 `-s 192.168.1.11` 可只接受 FPGA 来源的包

## 支持的字符

- 中国省份简称：京沪津渝冀晋蒙辽吉黑苏浙皖闽赣鲁豫鄂湘粤桂琼川贵云藏陕甘青宁新
- 特殊车牌：学警港澳挂使领民航危险品
- 数字：0-9
- 字母：A-Z（不含 I、O）
