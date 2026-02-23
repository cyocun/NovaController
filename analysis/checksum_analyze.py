#!/usr/bin/env python3
"""Analyze checksum algorithm from captured NovaStar MSD300 packets."""

# Known packets: full hex data including checksum (last 2 bytes)
packets = [
    # brightness commands (21 bytes) from capture 1 and 2
    "55aa00fafe0001ffffff01000100000201000c5c5a",
    "55aa00fcfe0001ffffff01000100000201000d5f5a",
    "55aa00fefe0001ffffff01000100000201000e625a",
    "55aa0000fe0001ffffff01000100000201000f6559",
    "55aa0010fe0001ffffff01000100000201000e7459",
    "55aa0012fe0001ffffff01000100000201000d7559",
    "55aa0014fe0001ffffff01000100000201000c7659",
    "55aa0016fe0001ffffff01000100000201000b7759",
    "55aa0018fe0001ffffff01000100000201000a7859",
    "55aa001afe0001ffffff0100010000020100097959",
    "55aa001cfe0001ffffff0100010000020100087a59",
    "55aa002cfe0001ffffff0100010000020100098b59",
    # from capture 2
    "55aa0040fe0001ffffff0100010000020100099f59",
    "55aa0042fe0001ffffff0100010000020100ff975a",
    "55aa0044fe0001ffffff0100010000020100ff995a",
    "55aa0046fe0001ffffff0100010000020100ff9b5a",
    "55aa0048fe0001ffffff0100010000020100ff9d5a",
    "55aa0058fe0001ffffff010001000002010000ae59",
    "55aa005afe0001ffffff010001000002010000b059",
    "55aa005cfe0001ffffff010001000002010000b259",
    # 20-byte read commands
    "55aa00e8fe000000000000000200000002003f57",
    "55aa0011fe000000000000001600000008008256",
    "55aa0028fe000000000000000600000001008256",
    # 24-byte color commands
    "55aa00fbfe0001ffffff0100e30100020400f0f0f000075e",
    "55aa00fdfe0001ffffff0100e30100020400f0f0f000095e",
    "55aa00fffe0001ffffff0100e30100020400f0f0f0000b5e",
    "55aa0001fe0001ffffff0100e30100020400f0f0f0000d5d",
    "55aa0041fe0001ffffff0100e30100020400f0f0f0004d5d",
    "55aa0043fe0001ffffff0100e30100020400f0f0f0004f5d",
]

print("=== Checksum Analysis ===\n")

for pkt_hex in packets:
    data = bytes.fromhex(pkt_hex)
    payload = data[:-2]
    chk = data[-2:]

    # Try various algorithms
    # 1. Simple byte sum
    byte_sum = sum(payload) & 0xFFFF

    # 2. Sum excluding header (55 AA)
    sum_no_header = sum(payload[2:]) & 0xFFFF

    # 3. Sum of bytes, split into two separate sums (even/odd positions)
    sum_even = sum(payload[i] for i in range(0, len(payload), 2)) & 0xFF
    sum_odd = sum(payload[i] for i in range(1, len(payload), 2)) & 0xFF

    # 4. XOR of all bytes
    xor_all = 0
    for b in payload:
        xor_all ^= b

    # 5. Sum from byte 2 onwards, as two separate byte sums
    sum_a = sum(payload[2::2]) & 0xFF  # even positions from byte 2
    sum_b = sum(payload[3::2]) & 0xFF  # odd positions from byte 3

    # 6. Cumulative sum approach
    cum_sum = 0
    for b in payload[2:]:
        cum_sum = (cum_sum + b) & 0xFFFF

    actual_chk = f"{chk[0]:02x}{chk[1]:02x}"

    print(f"Packet: ...{pkt_hex[-10:]}")
    print(f"  Actual checksum:     {actual_chk}")
    print(f"  Byte sum (all):      {byte_sum:04x}")
    print(f"  Sum (no header):     {sum_no_header:04x}")
    print(f"  Even/Odd sums:       {sum_even:02x}/{sum_odd:02x}")
    print(f"  Sum from byte2 e/o:  {sum_a:02x}/{sum_b:02x}")
    print(f"  Cumulative sum:      {cum_sum:04x}")
    print()

# Try to find the relationship by looking at differences
print("\n=== Difference Analysis (brightness commands only) ===\n")
brightness_pkts = [
    ("55aa0040fe0001ffffff0100010000020100099f59", 0x09),
    ("55aa0042fe0001ffffff0100010000020100ff975a", 0xff),
    ("55aa0044fe0001ffffff0100010000020100ff995a", 0xff),
    ("55aa0058fe0001ffffff010001000002010000ae59", 0x00),
]

for pkt_hex, bri in brightness_pkts:
    data = bytes.fromhex(pkt_hex)
    payload = data[:-2]
    chk_hi, chk_lo = data[-2], data[-1]
    seq = (payload[2] << 8) | payload[3]

    # Try: checksum = f(sum_of_specific_bytes)
    s = sum(payload[4:]) & 0xFFFF  # sum from byte 4 onwards

    print(f"seq={seq:04x} bri={bri:02x} chk={chk_hi:02x}{chk_lo:02x} sum4+={s:04x} sum_all={sum(payload)&0xFFFF:04x}")
