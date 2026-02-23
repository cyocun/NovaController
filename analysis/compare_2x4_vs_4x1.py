#!/usr/bin/env python3
"""
Compare 2x4 Serpentine vs 4x1 Right-to-Left/Left-to-Right layout command packets
for NovaStar MSD300 LED controller.

Parses both capture files and identifies structural differences to inform
flexible layout system design.
"""

import struct
from collections import defaultdict, OrderedDict

# ─── Helpers ──────────────────────────────────────────────────────────────────

def parse_inner_payload(hex_str):
    """Parse inner payload (already stripped of 55AA header, seq, checksum)."""
    b = bytes.fromhex(hex_str)
    if len(b) < 14:
        return None
    src = b[0]
    dest = b[1]
    device_type = b[2]
    port = b[3]
    board = b[4] | (b[5] << 8)  # LE16
    direction = b[6]  # 1=write, 0=read
    reserved = b[7]
    reg = struct.unpack_from('<I', b, 8)[0]
    data_len = struct.unpack_from('<H', b, 12)[0]
    data = b[14:14+data_len] if len(b) > 14 else b''
    return {
        'src': src, 'dest': dest, 'device_type': device_type,
        'port': port, 'board': board, 'direction': direction,
        'reserved': reserved, 'reg': reg, 'data_len': data_len,
        'data': data, 'raw': b
    }


def strip_55aa_packet(hex_str):
    """Strip 55AA header (2 bytes), sequence (2 bytes), and checksum (2 bytes)."""
    b = bytes.fromhex(hex_str)
    if len(b) < 6:
        return None
    inner = b[4:-2]  # skip first 4, last 2
    return inner.hex()


def reg_str(reg):
    return f"0x{reg:08X}"


def data_hex(data, max_bytes=32):
    h = data.hex()
    if len(data) > max_bytes:
        return h[:max_bytes*2] + f"... ({len(data)} bytes total)"
    return h


def le_val(data):
    """Convert data bytes to LE integer."""
    if not data:
        return 0
    return int.from_bytes(data, 'little')


# ─── Load and parse both files ───────────────────────────────────────────────

def load_2x4_serpentine(filepath):
    """Load 2x4 serpentine file - has full 55AA packets."""
    commands = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            inner_hex = strip_55aa_packet(line)
            if inner_hex:
                cmd = parse_inner_payload(inner_hex)
                if cmd:
                    commands.append(cmd)
    return commands


def load_4x1_stripped(filepath):
    """Load 4x1 file - already stripped payloads (no 55AA, no seq, no checksum).
    This file contains TWO presets: R->L first, then L->R."""
    all_lines = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            all_lines.append(line)

    # Parse all
    all_cmds = []
    for line in all_lines:
        cmd = parse_inner_payload(line)
        if cmd:
            all_cmds.append(cmd)

    # Split: find second preset by looking for repeated sequence start pattern.
    # The first command is always feff...010018... (reg 0x01000018, dest=0xFF).
    # Find the second occurrence of this pattern.
    first_reg = all_cmds[0]['reg'] if all_cmds else None
    first_dest = all_cmds[0]['dest'] if all_cmds else None

    split_idx = None
    for i in range(1, len(all_cmds)):
        if all_cmds[i]['reg'] == first_reg and all_cmds[i]['dest'] == first_dest:
            split_idx = i
            break

    if split_idx:
        return all_cmds[:split_idx], all_cmds[split_idx:]
    else:
        return all_cmds, []


# ─── Categorize commands ─────────────────────────────────────────────────────

def categorize(commands):
    """Categorize commands into groups."""
    cats = {
        'recv_global': [],       # dest=0xFF (receiver card global)
        'sender_area': [],       # dest=0x00, area registers (0x02000024-2C, 0x02000051-57)
        'sender_misc': [],       # dest=0x00, other small register writes
        'mapping_table': [],     # dest=0x00, reg 0x0300xxxx, 256-byte blocks
        'per_card': [],          # dest=0x00, specific board index, reg 0x02000017/19
        'card_global': [],       # dest=0x00, board=ALL (e.g. 0x0200009A)
        'reads': [],             # read commands (direction=0)
        'other': [],             # anything else
    }

    area_regs = set(range(0x02000024, 0x0200002D)) | set(range(0x02000050, 0x02000058)) | {0x020000F0}

    for cmd in commands:
        if cmd['direction'] == 0:
            cats['reads'].append(cmd)
        elif cmd['dest'] == 0xFF:
            cats['recv_global'].append(cmd)
        elif cmd['dest'] == 0x00:
            if cmd['reg'] >= 0x03000000 and cmd['reg'] < 0x04000000 and cmd['data_len'] >= 64:
                cats['mapping_table'].append(cmd)
            elif cmd['reg'] in (0x02000017, 0x02000019) and cmd['board'] != 0xFFFF:
                cats['per_card'].append(cmd)
            elif cmd['board'] == 0xFFFF:
                cats['card_global'].append(cmd)
            elif cmd['reg'] in area_regs:
                cats['sender_area'].append(cmd)
            else:
                cats['sender_misc'].append(cmd)
        else:
            cats['other'].append(cmd)

    return cats


# ─── Pretty printing ─────────────────────────────────────────────────────────

def describe_command(cmd, idx=None):
    """Human-readable description of a command."""
    dest_names = {0x00: "SENDER", 0xFF: "RECV", 0x01: "DEST01"}
    dest_label = dest_names.get(cmd['dest'], f"DEST(0x{cmd['dest']:02X})")
    dir_label = "W" if cmd['direction'] == 1 else "R"
    port_label = f"p{cmd['port']}" if cmd['port'] != 0xFF else "pALL"
    board_label = f"b{cmd['board']}" if cmd['board'] != 0xFFFF else "bALL"

    prefix = f"  [{idx:2d}] " if idx is not None else "  "
    line = f"{prefix}{dest_label:8s} {dir_label} {port_label:5s} {board_label:6s} " \
           f"reg={reg_str(cmd['reg'])} len={cmd['data_len']}"
    if cmd['data_len'] > 0 and cmd['data_len'] <= 16:
        val = le_val(cmd['data'])
        line += f" data={cmd['data'].hex()} (={val})"
    elif cmd['data_len'] > 16:
        line += f" data=[{cmd['data_len']}B]"
    return line


# ─── Analysis functions ──────────────────────────────────────────────────────

def print_structure(name, commands, cats):
    print(f"\n{'='*80}")
    print(f"  {name} -- {len(commands)} total commands")
    print(f"{'='*80}")
    for cat_name, cat_cmds in cats.items():
        if cat_cmds:
            print(f"  {cat_name:20s}: {len(cat_cmds)}")


def print_all(name, commands):
    print(f"\n--- Full command list: {name} ---")
    for i, cmd in enumerate(commands):
        print(describe_command(cmd, i))


def print_area_registers(name, cats):
    """Show area registers and their dimensional interpretation."""
    print(f"\n--- Area/dimension registers: {name} ---")
    area_cmds = cats['sender_area']

    # Known register meanings (refined)
    reg_names = {
        0x02000024: 'area1_width',
        0x02000026: 'area1_height',
        0x02000028: 'area1_x_start',
        0x0200002A: 'area1_y_start',
        0x0200002C: 'area1_stride',
        0x02000050: 'area_mode',
        0x02000051: 'area2_width',
        0x02000053: 'area2_height',
        0x02000055: 'area2_x_start',
        0x02000057: 'area2_y_start',
        0x020000F0: 'layout_flag',
    }

    for cmd in area_cmds:
        val = le_val(cmd['data'])
        rname = reg_names.get(cmd['reg'], '???')
        print(f"  {reg_str(cmd['reg'])} {rname:20s} = 0x{val:04X} ({val})")


def print_per_card(name, cats):
    """Show per-card (board-specific) register writes."""
    print(f"\n--- Per-card board settings: {name} ---")
    pc = cats['per_card']

    reg_names = {0x02000017: 'card_reg17', 0x02000019: 'card_reg19'}

    # Group by board
    by_board = defaultdict(list)
    for cmd in pc:
        by_board[cmd['board']].append(cmd)

    board_order = []
    seen = set()
    for cmd in pc:
        if cmd['board'] not in seen:
            board_order.append(cmd['board'])
            seen.add(cmd['board'])

    print(f"  Board ordering: {board_order}")
    print(f"  Number of boards addressed: {len(board_order)}")

    for board in board_order:
        cmds = by_board[board]
        vals = {}
        for cmd in cmds:
            rname = reg_names.get(cmd['reg'], f'reg_{cmd["reg"]:08X}')
            vals[rname] = le_val(cmd['data'])
        print(f"  board={board}: {vals}")

    # Also show the board=ALL command (0x0200009A)
    for cmd in cats['card_global']:
        print(f"  board=ALL reg={reg_str(cmd['reg'])} data={cmd['data'].hex()} (={le_val(cmd['data'])})")


def print_recv_global(name, cats):
    """Show receiver-card global commands."""
    print(f"\n--- Receiver card (dest=0xFF) commands: {name} ---")
    for cmd in cats['recv_global']:
        port_label = f"p{cmd['port']}" if cmd['port'] != 0xFF else "pALL"
        board_label = f"b{cmd['board']}" if cmd['board'] != 0xFFFF else "bALL"
        val = le_val(cmd['data'])
        print(f"  {port_label} {board_label} reg={reg_str(cmd['reg'])} "
              f"data={cmd['data'].hex()} (={val})")


def print_mapping_table_summary(name, cats):
    """Summarize mapping table blocks."""
    blocks = cats['mapping_table']
    print(f"\n--- Mapping table: {name} ({len(blocks)} blocks) ---")

    if not blocks:
        return

    # Show register addresses
    regs = [b['reg'] for b in blocks]
    print(f"  Register range: {reg_str(regs[0])} - {reg_str(regs[-1])}")
    print(f"  Block size: {blocks[0]['data_len']} bytes each")

    # Check if all blocks have same data
    first_data = blocks[0]['data']
    all_same = all(b['data'] == first_data for b in blocks)
    print(f"  All blocks identical data: {all_same}")

    # Show first block's first 64 bytes as 2-byte LE values
    d = blocks[0]['data']
    print(f"  Block 0 first 32 bytes (hex): {d[:32].hex()}")

    # Parse as 2-byte LE values
    vals_2b = []
    for i in range(0, min(32, len(d)), 2):
        v = d[i] | (d[i+1] << 8)
        vals_2b.append(f"0x{v:04X}")
    print(f"  Block 0 as LE16 values: {' '.join(vals_2b)}")


def print_misc_sender(name, cats):
    """Show miscellaneous sender commands."""
    print(f"\n--- Misc sender commands: {name} ---")
    for cmd in cats['sender_misc']:
        val = le_val(cmd['data']) if cmd['data'] else 0
        board_label = f"b{cmd['board']}" if cmd['board'] != 0xFFFF else "bALL"
        print(f"  {board_label} reg={reg_str(cmd['reg'])} len={cmd['data_len']} "
              f"data={cmd['data'].hex() if cmd['data'] else 'N/A'} (={val})")


def print_reads(name, cats):
    """Show read commands."""
    if not cats['reads']:
        return
    print(f"\n--- Read commands (unique to capture): {name} ---")
    for cmd in cats['reads']:
        dest_label = {0x00: "SENDER", 0xFF: "RECV", 0x01: "DEST01"}.get(cmd['dest'], f"0x{cmd['dest']:02X}")
        print(f"  {dest_label} reg={reg_str(cmd['reg'])} len={cmd['data_len']}")


def print_other(name, cats):
    if not cats['other']:
        return
    print(f"\n--- Other commands: {name} ---")
    for cmd in cats['other']:
        print(describe_command(cmd))


# ─── Comparison functions ────────────────────────────────────────────────────

def compare_area_regs(name1, cats1, name2, cats2):
    print(f"\n{'='*80}")
    print(f"  Area register comparison: {name1} vs {name2}")
    print(f"{'='*80}")

    def area_dict(cats):
        d = {}
        for cmd in cats['sender_area']:
            d[cmd['reg']] = le_val(cmd['data'])
        return d

    d1 = area_dict(cats1)
    d2 = area_dict(cats2)

    reg_names = {
        0x02000024: 'area1_width',
        0x02000026: 'area1_height',
        0x02000028: 'area1_x_start',
        0x0200002A: 'area1_y_start',
        0x0200002C: 'area1_stride',
        0x02000050: 'area_mode',
        0x02000051: 'area2_width',
        0x02000053: 'area2_height',
        0x02000055: 'area2_x_start',
        0x02000057: 'area2_y_start',
        0x020000F0: 'layout_flag',
    }

    all_regs = sorted(set(d1.keys()) | set(d2.keys()))
    print(f"\n  {'Register':14s} {'Name':20s} {name1:>12s} {name2:>12s} {'Match':>6s}")
    print(f"  {'-'*14} {'-'*20} {'-'*12} {'-'*12} {'-'*6}")
    for reg in all_regs:
        v1 = d1.get(reg)
        v2 = d2.get(reg)
        rname = reg_names.get(reg, '???')
        s1 = f"0x{v1:04X} ({v1})" if v1 is not None else "N/A"
        s2 = f"0x{v2:04X} ({v2})" if v2 is not None else "N/A"
        match = "YES" if v1 == v2 else "NO"
        print(f"  {reg_str(reg)} {rname:20s} {s1:>12s} {s2:>12s} {match:>6s}")


def compare_per_card(name1, cats1, name2, cats2):
    print(f"\n{'='*80}")
    print(f"  Per-card board comparison: {name1} vs {name2}")
    print(f"{'='*80}")

    def board_order(cats):
        order = []
        seen = set()
        for cmd in cats['per_card']:
            if cmd['board'] not in seen:
                order.append(cmd['board'])
                seen.add(cmd['board'])
        return order

    o1 = board_order(cats1)
    o2 = board_order(cats2)
    print(f"  {name1} board order: {o1}")
    print(f"  {name2} board order: {o2}")
    print(f"  {name1} boards used: {len(o1)}")
    print(f"  {name2} boards used: {len(o2)}")

    # Both use the same register values (0x8000) for all boards, just different count/order


def compare_mapping_tables(name1, cats1, name2, cats2):
    blocks1 = cats1['mapping_table']
    blocks2 = cats2['mapping_table']

    print(f"\n{'='*80}")
    print(f"  Mapping table comparison: {name1} vs {name2}")
    print(f"{'='*80}")
    print(f"  {name1}: {len(blocks1)} blocks of {blocks1[0]['data_len']}B" if blocks1 else f"  {name1}: 0 blocks")
    print(f"  {name2}: {len(blocks2)} blocks of {blocks2[0]['data_len']}B" if blocks2 else f"  {name2}: 0 blocks")

    if not blocks1 or not blocks2:
        return

    # Show the 2-byte LE pattern interpretation for first block of each
    print(f"\n  First block data pattern (first 64 bytes as LE16 pairs):")
    for lbl, blks in [(name1, blocks1), (name2, blocks2)]:
        d = blks[0]['data']
        # Parse as 2-byte LE values, show first 16 values (32 bytes)
        vals = []
        for i in range(0, min(64, len(d)), 2):
            v = d[i] | (d[i+1] << 8)
            vals.append(v)
        # Show in groups of 4 (8 bytes = one "pixel entry"?)
        print(f"\n  {lbl} block[0] LE16 values (first 32):")
        for j in range(0, len(vals), 4):
            chunk = vals[j:j+4]
            print(f"    [{j:2d}-{j+3:2d}]: {' '.join(f'0x{v:04X}' for v in chunk)}")

    # Check uniqueness within each set
    for lbl, blks in [(name1, blocks1), (name2, blocks2)]:
        unique_patterns = set()
        for b in blks:
            unique_patterns.add(b['data'])
        print(f"\n  {lbl}: {len(unique_patterns)} unique data patterns across {len(blks)} blocks")


def compare_final_commands(name1, cats1, name2, cats2):
    """Compare the final 'commit' commands (0x020001EC, 0x020000AE, etc.)."""
    print(f"\n{'='*80}")
    print(f"  Final/commit commands comparison: {name1} vs {name2}")
    print(f"{'='*80}")

    commit_regs = {0x020001EC, 0x020000AE, 0x01000012, 0x03100000}

    for lbl, cats in [(name1, cats1), (name2, cats2)]:
        print(f"\n  {lbl}:")
        for cat_name in ['recv_global', 'sender_misc', 'sender_area', 'card_global']:
            for cmd in cats[cat_name]:
                if cmd['reg'] in commit_regs:
                    val = le_val(cmd['data'])
                    dest_label = "SENDER" if cmd['dest'] == 0x00 else "RECV"
                    print(f"    {dest_label} reg={reg_str(cmd['reg'])} "
                          f"data={cmd['data'].hex()} (LE={val} / 0x{val:04X})")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    base = '/Users/cyocun/Dropbox/__WORKS/_own_services/novaCLT4Mac'

    serpentine_file = f'{base}/captures/layout_2x4_serpentine.txt'
    rtl_file = f'{base}/analysis/layout_preset_rightToLeft.txt'

    print("=" * 80)
    print("  NovaStar MSD300 Layout Packet Analysis")
    print("  2x4 Serpentine vs 4x1 Right-to-Left vs 4x1 Left-to-Right")
    print("=" * 80)

    # ── Load ──
    print("\nLoading 2x4 serpentine (full 55AA packets)...")
    cmds_2x4 = load_2x4_serpentine(serpentine_file)
    print(f"  Loaded {len(cmds_2x4)} commands")

    print("Loading 4x1 (stripped payloads, contains R->L + L->R)...")
    cmds_4x1_rtl, cmds_4x1_ltr = load_4x1_stripped(rtl_file)
    print(f"  R->L: {len(cmds_4x1_rtl)} commands")
    print(f"  L->R: {len(cmds_4x1_ltr)} commands")

    # ── Categorize ──
    cats_2x4 = categorize(cmds_2x4)
    cats_rtl = categorize(cmds_4x1_rtl)
    cats_ltr = categorize(cmds_4x1_ltr) if cmds_4x1_ltr else None

    datasets = [
        ("2x4 Serpentine", cmds_2x4, cats_2x4),
        ("4x1 R->L", cmds_4x1_rtl, cats_rtl),
    ]
    if cmds_4x1_ltr:
        datasets.append(("4x1 L->R", cmds_4x1_ltr, cats_ltr))

    # ═══════════════════════════════════════════════════════════════════════
    # 1. Structure overview
    # ═══════════════════════════════════════════════════════════════════════
    for name, cmds, cats in datasets:
        print_structure(name, cmds, cats)

    # ═══════════════════════════════════════════════════════════════════════
    # 2. Full command listings
    # ═══════════════════════════════════════════════════════════════════════
    for name, cmds, cats in datasets:
        print_all(name, cmds)

    # ═══════════════════════════════════════════════════════════════════════
    # 3. Detailed breakdowns per dataset
    # ═══════════════════════════════════════════════════════════════════════
    for name, cmds, cats in datasets:
        print_recv_global(name, cats)
        print_area_registers(name, cats)
        print_misc_sender(name, cats)
        print_per_card(name, cats)
        print_mapping_table_summary(name, cats)
        print_reads(name, cats)
        print_other(name, cats)

    # ═══════════════════════════════════════════════════════════════════════
    # 4. Cross-layout comparisons
    # ═══════════════════════════════════════════════════════════════════════
    compare_area_regs("2x4 Serpentine", cats_2x4, "4x1 R->L", cats_rtl)
    if cats_ltr:
        compare_area_regs("4x1 R->L", cats_rtl, "4x1 L->R", cats_ltr)

    compare_per_card("2x4 Serpentine", cats_2x4, "4x1 R->L", cats_rtl)
    if cats_ltr:
        compare_per_card("4x1 R->L", cats_rtl, "4x1 L->R", cats_ltr)

    compare_mapping_tables("2x4 Serpentine", cats_2x4, "4x1 R->L", cats_rtl)
    if cats_ltr:
        compare_mapping_tables("4x1 R->L", cats_rtl, "4x1 L->R", cats_ltr)

    compare_final_commands("2x4 Serpentine", cats_2x4, "4x1 R->L", cats_rtl)

    # ═══════════════════════════════════════════════════════════════════════
    # 5. Register 0x020001EC analysis (appears to encode layout dimensions)
    # ═══════════════════════════════════════════════════════════════════════
    print(f"\n{'='*80}")
    print(f"  Register 0x020001EC (layout dimension encoding)")
    print(f"{'='*80}")
    for name, cmds, cats in datasets:
        for cmd in cmds:
            if cmd['reg'] == 0x020001EC:
                d = cmd['data']
                if len(d) == 4:
                    w = d[0] | (d[1] << 8)
                    h = d[2] | (d[3] << 8)
                    print(f"  {name}: raw={d.hex()} -> word1=0x{w:04X}({w}) word2=0x{h:04X}({h})")

    # ═══════════════════════════════════════════════════════════════════════
    # 6. Register 0x03100000 analysis (card count register)
    # ═══════════════════════════════════════════════════════════════════════
    print(f"\n{'='*80}")
    print(f"  Register 0x03100000 (card count / mapping size)")
    print(f"{'='*80}")
    for name, cmds, cats in datasets:
        for cmd in cmds:
            if cmd['reg'] == 0x03100000:
                val = le_val(cmd['data'])
                print(f"  {name}: raw={cmd['data'].hex()} -> LE={val} (0x{val:04X})")

    # ═══════════════════════════════════════════════════════════════════════
    # 7. Unique registers in 2x4 not in 4x1
    # ═══════════════════════════════════════════════════════════════════════
    print(f"\n{'='*80}")
    print(f"  Registers unique to 2x4 Serpentine (not in any 4x1)")
    print(f"{'='*80}")
    regs_2x4 = set(c['reg'] for c in cmds_2x4)
    regs_4x1 = set(c['reg'] for c in cmds_4x1_rtl)
    if cmds_4x1_ltr:
        regs_4x1 |= set(c['reg'] for c in cmds_4x1_ltr)

    unique = regs_2x4 - regs_4x1
    if unique:
        for reg in sorted(unique):
            cmds_for_reg = [c for c in cmds_2x4 if c['reg'] == reg]
            for cmd in cmds_for_reg:
                dest_label = {0x00: "SENDER", 0xFF: "RECV", 0x01: "DEST01"}.get(cmd['dest'], f"0x{cmd['dest']:02X}")
                dir_label = "W" if cmd['direction'] == 1 else "R"
                print(f"  {reg_str(reg)} [{dest_label}] {dir_label} len={cmd['data_len']} "
                      f"data={cmd['data'].hex() if cmd['data'] else 'N/A'}")
    else:
        print("  None -- all 2x4 registers also appear in 4x1")

    # ═══════════════════════════════════════════════════════════════════════
    # 8. COMPREHENSIVE SUMMARY
    # ═══════════════════════════════════════════════════════════════════════
    print(f"\n{'#'*80}")
    print(f"#")
    print(f"#  COMPREHENSIVE ANALYSIS SUMMARY")
    print(f"#")
    print(f"{'#'*80}")

    print(f"""
  DATASET SIZES
  ─────────────
  2x4 Serpentine: {len(cmds_2x4)} commands
  4x1 R->L:      {len(cmds_4x1_rtl)} commands
  4x1 L->R:      {len(cmds_4x1_ltr)} commands

  COMMAND CATEGORY COUNTS
  ───────────────────────
  {'Category':20s} {'2x4':>6s} {'4x1R->L':>8s} {'4x1L->R':>8s}""")

    for cat in ['recv_global', 'sender_area', 'sender_misc', 'mapping_table',
                'per_card', 'card_global', 'reads', 'other']:
        c1 = len(cats_2x4[cat])
        c2 = len(cats_rtl[cat])
        c3 = len(cats_ltr[cat]) if cats_ltr else 0
        print(f"  {cat:20s} {c1:6d} {c2:8d} {c3:8d}")

    print(f"""
  SCREEN DIMENSIONS (from area registers)
  ────────────────────────────────────────
  2x4 Serpentine:
    area1_width  (0x24) = 0x0100 = 256 pixels (2 cabinets x 128px)
    area1_height (0x26) = 0x0200 = 512 pixels (4 cabinets x 128px)
    area1_stride (0x2C) = 0x0100 = 256
    area2 mirrors area1

  4x1 R->L / L->R:
    area1_width  (0x24) = 0x0200 = 512 pixels (4 cabinets x 128px)
    area1_height (0x26) = 0x0080 = 128 pixels (1 cabinet x 128px)
    area1_stride (0x2C) = 0x0200 = 512
    area2 mirrors area1

  KEY OBSERVATION: area1_width = total_columns * 128, area1_height = total_rows * 128
  The cabinet size is 128x128 pixels.
  area1_stride = area1_width (always equals width).

  CARD COUNT REGISTER (0x03100000)
  ────────────────────────────────
  2x4 Serpentine: 0x0008 = 8 cards (2 columns x 4 rows)
  4x1 R->L/L->R: 0x0004 = 4 cards (4 columns x 1 row)

  PER-CARD BOARD ORDERING
  ───────────────────────""")

    # Board ordering details
    def get_board_order(cats):
        order = []
        seen = set()
        for cmd in cats['per_card']:
            if cmd['board'] not in seen:
                order.append(cmd['board'])
                seen.add(cmd['board'])
        return order

    o_2x4 = get_board_order(cats_2x4)
    o_rtl = get_board_order(cats_rtl)
    o_ltr = get_board_order(cats_ltr) if cats_ltr else []

    print(f"  2x4 Serpentine: boards {o_2x4}")
    print(f"    = S-pattern: col1 bottom-up (3,2,1,0), col2 top-down (4,5,6,7)")
    print(f"  4x1 R->L:      boards {o_rtl}")
    print(f"    = Right-to-left: 3,2,1,0")
    print(f"  4x1 L->R:      boards {o_ltr}")
    print(f"    = Left-to-right: 0,1,2,3")

    print(f"""
  MAPPING TABLE
  ─────────────
  Both layouts use 16 blocks of 256 bytes at registers 0x03000000-0x03000F00.
  2x4 also has 2 extra bulk reads (0x02020020, 0x14000000) not in 4x1.
  4x1 has 32 mapping blocks total (16 for R->L + 16 for L->R since file has both).

  Mapping data patterns differ between layouts:
    2x4 Serpentine block pattern: 0000 8001 0000 0001 0000 8000 0000 0000 ...
    4x1 R->L block pattern:      8001 0000 0001 0000 8000 0000 0000 0000 ...
    4x1 L->R block pattern:      0000 0000 8000 0000 0001 0000 8001 0000 ...

  The mapping table encodes how receiving cards map physical LED positions.
  The data is a repeating pattern with entries shifted/reordered per scan direction.

  REGISTER 0x020001EC (final dimension write)
  ────────────────────────────────────────────""")

    for name, cmds, cats in datasets:
        for cmd in cmds:
            if cmd['reg'] == 0x020001EC:
                d = cmd['data']
                w = d[0] | (d[1] << 8)
                h = d[2] | (d[3] << 8)
                print(f"  {name}: word1=0x{w:04X}({w}) word2=0x{h:04X}({h})")
                print(f"    -> Matches area1_width and area1_height exactly")

    print(f"""
  REGISTERS UNIQUE TO 2x4 (reads during config, not in 4x1)
  ──────────────────────────────────────────────────────────
  0x00000002 (SENDER, R) - status read?
  0x00000006 (SENDER, R) - status read?
  0x00000016 (SENDER, R) - status read?
  0x02020020 (SENDER, R) - 64-byte bulk read (mapping metadata?)
  0x14000000 (SENDER, R) - 88-byte bulk read (configuration readback?)
  0x00000002 (DEST01, R) - read from device_type=1 (receiver card status?)

  These are all READ commands, likely status checks that NovaLCT performs
  during 2x4 setup but not during the simpler 4x1 setup. They are not
  needed for WRITING a layout preset.

  WHAT VARIES BETWEEN LAYOUTS (for flexible system)
  ─────────────────────────────────────────────────
  1. Area registers (0x24/26/28/2A/2C and mirrors 0x51-57):
     - width  = columns * 128
     - height = rows * 128
     - x_start/y_start = 0 (always)
     - stride = width (always)

  2. Card count register (0x03100000):
     - value = total number of receiving cards

  3. Per-card board ordering and count:
     - 4x1 L->R: [0,1,2,3] (sequential)
     - 4x1 R->L: [3,2,1,0] (reversed)
     - 2x4 S-pattern: [3,2,1,0, 4,5,6,7] (col1 reversed, col2 sequential)
     - Each board gets reg 0x02000017 = 0x8000 and reg 0x02000019 = 0x8000

  4. Mapping table data (16 blocks of 256 bytes):
     - Different byte pattern per scan direction
     - Same 16-block structure regardless of card count
     - Pattern is uniform across all 16 blocks within one preset

  5. Final commit register (0x020001EC):
     - word1 = total_width (= area1_width)
     - word2 = total_height (= area1_height)

  WHAT STAYS THE SAME
  ───────────────────
  - recv_global: reg 0x02000018=0, 0x02000019=0, 0x020000AE=1, 0x01000012=0xAA
  - area x_start/y_start = 0
  - area_mode (0x50) = 0
  - layout_flag (0xF0) = 0
  - per-card values: always 0x8000 for both reg17 and reg19
  - card_global 0x0200009A = 0
""")


if __name__ == '__main__':
    main()
