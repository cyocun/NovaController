# NovaController

[🇯🇵 日本語](./README.ja.md) | **🇬🇧 English**

A native macOS (SwiftUI) application for controlling the NovaStar **MSD300**
LED processor. Built to replace the Windows-only official tool **NovaLCT** on
macOS, via USB-UART communication reverse-engineered from USBPcap captures.
MSD300-only by design.

## Features

- **Layout presets** — three capture-verified patterns
  - 4×1 left-to-right
  - 4×1 right-to-left
  - 2×4 serpentine
- **Brightness control** — drag-based 270° gauge (0–100%), quick presets
  (0 / 25 / 50 / 75 / 100%), and schedule UI
- **Auto USB connect** — detects CP210x and opens the serial port on launch
- **Native macOS UI** — SwiftUI, resizable window

## Requirements

- macOS 14 Sonoma or later
- Xcode 15 or later (to build)
- NovaStar MSD300
- Silicon Labs CP210x VCP driver (bundled with macOS 10.13+)

## Build

```bash
xcodebuild -project NovaController/NovaController.xcodeproj -scheme NovaController build
```

Or open `NovaController/NovaController.xcodeproj` in Xcode and Run.

## Project Structure

```
NovaController/
├── NovaController.xcodeproj/
└── NovaController/
    ├── NovaControllerApp.swift   # app entry point
    ├── ContentView.swift          # sidebar, error banner, connection status
    ├── LayoutView.swift           # layout preset UI + preview
    ├── BrightnessView.swift       # brightness UI (circular gauge)
    ├── USBManager.swift           # IOKit + CP210x serial, packet assembly
    └── Extensions.swift           # Color(hex:) helper
captures/                          # USBPcap captures (.pcap / .txt)
analysis/                          # protocol analysis scripts / notes
tools/wireshark/                   # Wireshark dissector (dev tool)
novastar-msd300-notes.md           # packet spec / register map
```

## Developer Tool (optional)

`tools/wireshark/` includes a NovaStar Lua dissector for Wireshark. It auto-decodes
captured packets, which dramatically speeds up reverse engineering of new features.
See [`tools/wireshark/README.md`](./tools/wireshark/README.md) for setup.

## Protocol at a Glance

- Transport: Silicon Labs CP210x USB-UART bridge (VID `0x10C4`, PID `0xEA60`)
- Serial: 115200 baud, 8N1, no flow control
- Packet: `55 AA` header + 2-byte sequence + register-based R/W
- Checksum: `(0x5555 + sum(payload)) & 0xFFFF`, stored little-endian

See [`novastar-msd300-notes.md`](./novastar-msd300-notes.md) and
[`analysis/layout_protocol_analysis.md`](./analysis/layout_protocol_analysis.md)
for details.

## Status

| Feature | State | Notes |
|---|---|---|
| Brightness control | ✅ Implemented | Verified against 5 captured packets |
| Layout presets | ⚠️ Implemented (potential bugs) | 3 patterns reproduced from captures; final on-device verification pending |
| Temperature / health monitoring | 🔲 Not implemented | Register map available in `sarakusha/novastar` — no new captures needed |
| Auto brightness (light sensor) | 🔲 Not implemented | Design notes in `analysis/brightness_sensor_notes.md` |

## Related Projects

- NovaStar official: <https://www.novastar.tech/>
- Reference implementations:
  - [sarakusha/novastar](https://github.com/sarakusha/novastar) — TypeScript, MIT. Source for protocol spec and receiver-card monitoring registers.
  - [dietervansteenwegen/Novastar_MCTRL300_basic_controller](https://github.com/dietervansteenwegen/Novastar_MCTRL300_basic_controller)

## License

MIT License — see [`LICENSE`](./LICENSE).
Third-party attributions are in [`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md).

## Disclaimer & Trademarks

- This is an **unofficial** project and is **not affiliated with** NovaStar
  Technology Co., Ltd.
- *NovaStar* and *MSD300* are trademarks or registered trademarks of
  NovaStar Technology Co., Ltd.
- The implementation was developed independently through reverse engineering;
  no official NovaLCT code or binaries are included.
- Use at your own risk. The authors are not responsible for any damage to
  devices, loss of warranty, or other consequences arising from the use of
  this software.
