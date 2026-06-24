#!/usr/bin/env python3
import argparse
import socket
import struct
import sys
import time
from pathlib import Path


def rgb565_to_rgb888(pixel):
    r = (pixel >> 11) & 0x1F
    g = (pixel >> 5) & 0x3F
    b = pixel & 0x1F
    r = (r << 3) | (r >> 2)
    g = (g << 2) | (g >> 4)
    b = (b << 3) | (b >> 2)
    return r, g, b


def save_frame_ppm(frame_lines, width, height, out_path):
    with out_path.open("wb") as f:
        header = f"P6\n{width} {height}\n255\n".encode("ascii")
        f.write(header)
        for y in range(height):
            line = frame_lines[y]
            for pixel in line:
                f.write(bytes(rgb565_to_rgb888(pixel)))


def main():
    parser = argparse.ArgumentParser(description="Receive FPGA UDP line packets and rebuild RGB565 frames.")
    parser.add_argument("--bind-ip", default="0.0.0.0", help="Local IP to bind")
    parser.add_argument("--port", type=int, default=8080, help="UDP port")
    parser.add_argument("--width", type=int, default=640, help="Frame width")
    parser.add_argument("--height", type=int, default=360, help="Frame height")
    parser.add_argument("--output-dir", default="captures", help="Directory to save PPM frames")
    parser.add_argument("--timeout", type=float, default=5.0, help="Socket timeout in seconds")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    expected_len = 6 + args.width * 2
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind_ip, args.port))
    sock.settimeout(args.timeout)

    current_frame_id = None
    frame_lines = {}
    saved_frames = 0
    packet_count = 0
    start_time = time.time()

    print(f"Listening on {args.bind_ip}:{args.port}, expecting {args.width}x{args.height}, payload {expected_len} bytes")

    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            elapsed = time.time() - start_time
            print(f"Timeout after {elapsed:.1f}s, packets={packet_count}, saved_frames={saved_frames}")
            continue
        except KeyboardInterrupt:
            print("Stopped by user")
            return 0

        packet_count += 1

        if len(data) != expected_len:
            print(f"Skip packet from {addr}: unexpected length {len(data)} != {expected_len}")
            continue

        frame_id = struct.unpack(">I", data[0:4])[0]
        line_id = ((data[4] & 0x03) << 8) | data[5]

        if line_id >= args.height:
            print(f"Skip packet from {addr}: invalid line_id {line_id}")
            continue

        pixels = []
        payload = data[6:]
        for i in range(0, len(payload), 2):
            pixels.append((payload[i] << 8) | payload[i + 1])

        if current_frame_id is None:
            current_frame_id = frame_id

        if frame_id != current_frame_id:
            missing = args.height - len(frame_lines)
            print(f"Frame switch {current_frame_id} -> {frame_id}, collected {len(frame_lines)}/{args.height}, missing {missing}")
            frame_lines = {}
            current_frame_id = frame_id

        frame_lines[line_id] = pixels

        if len(frame_lines) == args.height:
            ordered = [frame_lines[y] for y in range(args.height)]
            out_path = output_dir / f"frame_{current_frame_id:08d}.ppm"
            save_frame_ppm(ordered, args.width, args.height, out_path)
            saved_frames += 1
            elapsed = time.time() - start_time
            fps = saved_frames / elapsed if elapsed > 0 else 0.0
            print(f"Saved {out_path} from {addr}, packets={packet_count}, fps={fps:.2f}")
            frame_lines = {}
            current_frame_id = None


if __name__ == "__main__":
    sys.exit(main())
