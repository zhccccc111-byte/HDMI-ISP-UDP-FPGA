# HDMI-ISP-UDP-FPGA

HDMI video capture, ISP processing, DDR3 frame buffering, and UDP streaming on Pango Logos2 FPGA.

## Architecture

```
HDMI Input (RGB888)
  -> Gamma Correction (LUT x3)
  -> Gaussian Filter (3x3 matrix)
  -> CSC (RGB -> YUV)
  -> Edge Enhancement (sharpening)
  -> OCC (YUV -> RGB)
  -> 3x Downscale (1920x1080 -> 640x360)
  -> RGB565 Pack
  -> DDR3 Frame Buffer (write)
  -> DDR3 Frame Reader
  -> UDP/IP/MAC/RGMII (Gigabit Ethernet)
```

## Target Device

- **FPGA**: Pango Logos2 PG2L100H-6 (FBG676)
- **Toolchain**: Pango Design Suite 2022.2-SP6.4
- **Top Module**: `hdmi_ddr_eth_top` (`source/rtl/hdmi_ddr_eth_top.v`)

## Key Parameters

| Parameter | Value |
|---|---|
| Image Size | 640 x 360 |
| Pixel Format | RGB565 |
| DDR3 Data Width | 32-bit |
| Local IP | 192.168.1.11 |
| Local Port | 8080 |
| Dest IP | 192.168.1.105 |
| Dest Port | 8080 |

## Directory Structure

```
source/
  rtl/            # Top-level, DDR frame writer/reader, frame buffer
  eth/            # UDP/IP/MAC/ARP stack, RGMII interface
  hdmi/           # MS7200/MS7210 HDMI chip I2C configuration
  img_process/    # Gamma lookup table
  tools/          # PC-side UDP receiver script (Python)
  *.v             # ISP modules (gauss, CSC, EE, OCC, downscaler, LCD)
ipcore/           # IP cores (DDR3 controller, PLL, FIFO)
sim_prj/          # Simulation project
matlab/           # MATLAB reference scripts
*.pds             # Pango Design Suite project file
*.fdc             # Pin and clock constraints
```

## ISP Processing Chain

All ISP modules run in the `pixclk_in` domain (~148.5 MHz for 1080p input):

1. **Gamma** - Per-channel gamma correction via lookup table
2. **Gaussian** - 3x3 spatial low-pass filter (implemented with matrix_3x3 + line buffer FIFO)
3. **CSC** - Color space conversion RGB -> YUV
4. **EE** - Edge enhancement / sharpening in YUV domain
5. **OCC** - Color space conversion YUV -> RGB
6. **Downscaler** - 3x bilinear downsample (1920x1080 -> 640x360)

## Clock Domains

| Clock | Frequency | Purpose |
|---|---|---|
| sys_clk | 27 MHz | System config, I2C |
| pixclk_in | ~148.5 MHz | HDMI pixel, ISP chain |
| ddrphy_sysclk | 200 MHz | DDR3 controller |
| rgmii_clk_90p | 125 MHz | Gigabit Ethernet RGMII |

## UDP Packet Format

Each UDP packet carries one scanline (1286 bytes):

```
Byte [0..3]  : frame_id (big-endian)
Byte [4..5]  : line_id (0..359)
Byte [6..1285]: 640 pixels x RGB565 (high byte first)
```

## PC-Side Receiver

```bash
python source/tools/udp_frame_dump.py --bind-ip 0.0.0.0 --port 8080 --width 640 --height 360 --output-dir ./captures
```

Receives UDP packets, reassembles frames, converts RGB565 to RGB888, saves as .ppm.

## Timing Status

All constraints met. Key WNS margins:

- pixclk_in: +2.1 ns
- ddrphy_sysclk: +3.3 ns
- rgmii_clk_90p: +3.1 ns

## Documentation

- [Bringup Guide](source/HDMI_DDR_ETH_bringup.md) - Board-level debugging and setup
- [Integration Flow](source/HDMI_DDR_ETH_merge_flow.md) - How the design was assembled
