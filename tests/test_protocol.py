"""Unit tests for the pure protocol helpers in bin/aula-f75.

They run anywhere (no device, no Linux ioctls) and pin the byte layout to
frames captured from the vendor driver, so a refactor cannot silently move
an offset.
"""
import importlib.machinery
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "..", "bin", "aula-f75")

# The CLI has no .py extension, so name the loader explicitly.
_loader = importlib.machinery.SourceFileLoader("aula_f75", CLI)
spec = importlib.util.spec_from_loader("aula_f75", _loader)
m = importlib.util.module_from_spec(spec)
_loader.exec_module(m)

# Frame 2 of the vendor driver's "Fixed on" write (USB capture, 258a:010c).
CAPTURED_FIXED_ON = bytes.fromhex(
    "06 04 00 00 01 00 80 00"
    "00 03 03 01 00 00 04 04 07 00 01 20 01 00 00 00 00 00 02 00 02 01 00 ff 0a 00 00 01 01 00 03 01"
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ff ff 09 40 09 47 09 47"
    "09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47"
    "09 37 07 47 07 47 07 44 07 44 07 44 07 44 07 44 07 44 07 44 04 09 04 04 04 04 04 04 04 04 5a a5"
) + bytes(520 - 8 - 128)

# Wireless dongle frames from the vendor driver (3554:fa09).
WL_PROBE = bytes.fromhex("13 44 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 58")
WL_LED_PAGE0 = bytes.fromhex("13 04 0a 00 0e 00 03 03 01 00 00 04 04 07 00 03 20 01 00 69")
WL_LED_PAGE9 = bytes.fromhex("13 04 0a 09 02 5a a5 00 00 00 00 00 00 00 00 00 00 00 00 2b")


class WiredFraming(unittest.TestCase):
    def test_header_matches_capture(self):
        self.assertEqual(m.wired_header(0x04, 0, 1, 0, 0x80), CAPTURED_FIXED_ON[:8])

    def test_write_packets_single(self):
        pkts = m.wired_write_packets(m.CMD_LED, 0, m.TEMPLATE_LED_BLOCK)
        self.assertEqual(len(pkts), 1)
        self.assertEqual(len(pkts[0]), 520)
        self.assertEqual(pkts[0], CAPTURED_FIXED_ON)

    def test_write_packets_split(self):
        data = bytes(range(256)) * 3  # 768 bytes -> 2 chunks
        pkts = m.wired_write_packets(m.CMD_MATRIX, 1, data)
        self.assertEqual(len(pkts), 2)
        self.assertEqual(pkts[0][:8], bytes([6, 3, 1, 0, 2, 0, 0x00, 0x02]))
        self.assertEqual(pkts[1][:8], bytes([6, 3, 1, 0, 2, 1, 0x00, 0x01]))
        self.assertEqual(pkts[0][8:520], data[:512])
        self.assertEqual(pkts[1][8:8 + 256], data[512:])

    def test_read_request(self):
        r = m.wired_read_request(m.CMD_LED, 0, 1, 0, 0x80)
        self.assertEqual(r[:8], bytes([6, 0x84, 0, 0, 1, 0, 0x80, 0]))
        self.assertEqual(len(r), 520)

    def test_colour_table_header(self):
        pkts = m.wired_write_packets(m.CMD_RGB_TABLE, 0, m.default_rgb_table())
        self.assertEqual(pkts[0][:8], bytes.fromhex("06 0a 00 00 01 00 00 02"))

    def test_perkey_header_matches_capture(self):
        pkts = m.wired_write_packets(m.CMD_PERKEY, 0, bytes(m.PERKEY_LEN))
        self.assertEqual(pkts[0][:8], bytes.fromhex("06 06 00 00 01 00 7a 01"))


class LedBlock(unittest.TestCase):
    def test_template_decodes(self):
        st = m.decode_led_block(m.TEMPLATE_LED_BLOCK)
        self.assertEqual(st["effect"], 1)
        self.assertEqual(st["effect_name"], "Fixed on")
        self.assertEqual(st["brightness"], 9)
        self.assertEqual(st["speed"], 4)
        self.assertEqual(st["colour_index"], 0)
        self.assertFalse(st["colorful"])
        self.assertEqual(st["sleep_hw"], 10)
        self.assertEqual(st["sleep_minutes"], 5)
        self.assertEqual(st["debounce"], 1)
        self.assertTrue(st["signature_ok"])

    def test_effect_byte_is_offset_10(self):
        for eid in (0, 2, 3, 17):
            b = m.patch_led_block(m.TEMPLATE_LED_BLOCK, effect=eid)
            self.assertEqual(b[10], eid)
            # nothing else moved (vendor capture: only byte 10 differs between effects)
            diff = [i for i in range(128) if b[i] != m.TEMPLATE_LED_BLOCK[i] and i != 10]
            self.assertEqual(diff, [])

    def test_custom_effect_sets_flag(self):
        b = m.patch_led_block(m.TEMPLATE_LED_BLOCK, effect=21)
        self.assertEqual(b[9], 1)
        self.assertEqual(b[10], 21)
        b = m.patch_led_block(b, effect=1)
        self.assertEqual(b[9], 0)

    def test_brightness_and_speed_table(self):
        b = m.patch_led_block(m.TEMPLATE_LED_BLOCK, brightness=5)
        self.assertEqual(b[0x3A], 5)                      # wireless capture: frame 42 byte 7 = 0x3a
        b = m.patch_led_block(b, colour_index=7)
        self.assertEqual(b[0x3B], 0x47)                   # capture: colourful on -> 0x47
        b = m.patch_led_block(b, colour_index=0)
        self.assertEqual(b[0x3B], 0x40)                   # capture: colourful off -> 0x40
        b = m.patch_led_block(b, speed=2)
        self.assertEqual(b[0x3B], 0x20)
        b = m.patch_led_block(m.TEMPLATE_LED_BLOCK, effect=3, brightness=4, speed=1, colour_index=7)
        self.assertEqual(b[0x38 + 6], 4)
        self.assertEqual(b[0x39 + 6], 0x17)

    def test_sleep_offset(self):
        b = m.patch_led_block(m.TEMPLATE_LED_BLOCK, sleep_hw=0x28)
        self.assertEqual(b[0x18], 0x28)                   # wireless sleep capture: frame 2 byte 15
        self.assertEqual(m.decode_led_block(b)["sleep_minutes"], 20)

    def test_sleep_mapping(self):
        self.assertEqual(m.sleep_hw_from_minutes("off"), 0)
        self.assertEqual(m.sleep_hw_from_minutes("1"), 2)
        self.assertEqual(m.sleep_hw_from_minutes("1.5"), 3)
        self.assertEqual(m.sleep_hw_from_minutes("5"), 10)
        self.assertEqual(m.sleep_hw_from_minutes("20"), 40)
        self.assertEqual(m.sleep_hw_from_minutes(7), 14)

    def test_debounce_offset_and_range(self):
        b = m.patch_led_block(m.TEMPLATE_LED_BLOCK, debounce=3)
        self.assertEqual(b[3], 3)
        with self.assertRaises(m.DeviceError):
            m.patch_led_block(m.TEMPLATE_LED_BLOCK, debounce=9)

    def test_signature_always_restored(self):
        broken = bytearray(m.TEMPLATE_LED_BLOCK)
        broken[0x7E:0x80] = b"\0\0"
        self.assertFalse(m.check_signature(broken, 0x7E))
        self.assertTrue(m.check_signature(m.patch_led_block(broken, brightness=1), 0x7E))

    def test_ranges(self):
        with self.assertRaises(m.DeviceError):
            m.patch_led_block(m.TEMPLATE_LED_BLOCK, brightness=10)
        with self.assertRaises(m.DeviceError):
            m.patch_led_block(m.TEMPLATE_LED_BLOCK, speed=5)
        with self.assertRaises(m.DeviceError):
            m.patch_led_block(m.TEMPLATE_LED_BLOCK, effect=19)


class RgbTable(unittest.TestCase):
    def test_slot_offsets(self):
        self.assertEqual(m.rgb_slot_offset(1, 0), 21)      # colour-change capture: frame 1 bytes 12..14
        self.assertEqual(m.rgb_slot_offset(2, 0), 42)
        self.assertEqual(m.rgb_slot_offset(1, 6), 39)

    def test_default_table(self):
        t = m.default_rgb_table()
        self.assertEqual(len(t), 512)
        self.assertEqual(t[21:24], b"\xff\x00\x00")
        self.assertEqual(t[0x1FA:0x1FC], b"\x5a\xa5")
        self.assertEqual(m.read_rgb_slot(t, 2, 1), (0, 255, 0))

    def test_patch(self):
        t = m.patch_rgb_table(bytes(512), 1, 0, (0x12, 0x34, 0x56))
        self.assertEqual(t[21:24], b"\x12\x34\x56")
        self.assertEqual(t[0x1FA:0x1FC], b"\x5a\xa5")


class Wireless(unittest.TestCase):
    def test_checksum_matches_capture(self):
        for f in (WL_PROBE, WL_LED_PAGE0, WL_LED_PAGE9):
            self.assertEqual(m.wl_checksum(f), f[19])

    def test_probe_frame(self):
        self.assertEqual(m.wl_read_request(0x44), WL_PROBE)

    def test_led_pages_match_capture(self):
        block = m.patch_led_block(m.TEMPLATE_LED_BLOCK, effect=3)
        pages = m.wl_pages(m.WL_CMD_LED, block)
        self.assertEqual(len(pages), 10)
        self.assertEqual(pages[0], WL_LED_PAGE0)
        self.assertEqual(pages[9], WL_LED_PAGE9)

    def test_rgb_pages(self):
        pages = m.wl_pages(m.WL_CMD_RGB_TABLE, m.default_rgb_table())
        self.assertEqual(len(pages), 37)
        self.assertEqual(pages[0][:5], bytes([0x13, 0x09, 0x25, 0x00, 0x0e]))
        self.assertEqual(pages[36][:5], bytes([0x13, 0x09, 0x25, 0x24, 0x08]))


class Parsing(unittest.TestCase):
    def test_effects(self):
        self.assertEqual(m.parse_effect("rainbow"), 3)
        self.assertEqual(m.parse_effect("Fixed on"), 1)
        self.assertEqual(m.parse_effect("fixed-on"), 1)
        self.assertEqual(m.parse_effect("off"), 0)
        self.assertEqual(m.parse_effect("custom"), 21)
        self.assertEqual(m.parse_effect("17"), 17)
        with self.assertRaises(m.DeviceError):
            m.parse_effect("disco")

    def test_colours(self):
        self.assertEqual(m.parse_colour("#ff8800"), (255, 136, 0))
        self.assertEqual(m.parse_colour("ff8800"), (255, 136, 0))
        self.assertEqual(m.parse_colour("#ffff8800"), (255, 136, 0))   # QML #AARRGGBB
        self.assertEqual(m.parse_colour("#f80"), (255, 136, 0))
        self.assertEqual(m.colour_hex((1, 2, 3)), "#010203")

    def test_keys(self):
        self.assertEqual(m.key_index("esc"), 0)
        self.assertEqual(m.key_index("Space"), 35)
        self.assertEqual(m.key_index("'"), 69)
        self.assertEqual(m.key_index("right"), 89)
        self.assertEqual(len(set(m.KEY_INDEX.values())), len(m.KEY_INDEX))
        for row in m.KEY_ROWS:
            for k in row:
                self.assertIn(k, m.KEY_INDEX)
        self.assertTrue(all(v < m.PERKEY_LEDS for v in m.KEY_INDEX.values()))


if __name__ == "__main__":
    unittest.main()


class HostLocks(unittest.TestCase):
    """The lock-key helpers that need no device."""

    def test_keycodes_are_the_kernel_ones(self):
        self.assertEqual(m.LOCK_KEYS["caps"][0], 58)    # KEY_CAPSLOCK
        self.assertEqual(m.LOCK_KEYS["num"][0], 69)     # KEY_NUMLOCK
        self.assertEqual(m.LOCK_KEYS["scroll"][0], 70)  # KEY_SCROLLLOCK

    def test_aliases(self):
        for alias, key in (("CapsLock", "caps"), ("num_lock", "num"), ("scrolllock", "scroll")):
            self.assertEqual(m.LOCK_ALIASES.get(alias.lower(), alias.lower()), key)

    def test_describe(self):
        self.assertEqual(m.describe_locks({"available": False}), "n/a")
        self.assertEqual(m.describe_locks({"available": True, "writable": True, "caps": True, "num": True}), "Caps, Num")
        self.assertIn("read-only", m.describe_locks({"available": True, "writable": False}))

    def test_udev_rule_covers_event_nodes_and_matches_shipped_file(self):
        self.assertIn('KERNEL=="event*"', m.UDEV_RULE)
        with open(os.path.join(HERE, "..", "udev", "60-aula-f75.rules"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), m.UDEV_RULE)


class WinLock(unittest.TestCase):
    """Byte 0x0f: observed flipping 00<->01 with Fn+Win on a real F75."""

    def test_decode(self):
        self.assertFalse(m.decode_led_block(m.TEMPLATE_LED_BLOCK)["winlock"])
        b = bytearray(m.TEMPLATE_LED_BLOCK); b[0x0F] = 1
        self.assertTrue(m.decode_led_block(bytes(b))["winlock"])

    def test_patch_only_touches_0x0f(self):
        out = m.patch_led_block(m.TEMPLATE_LED_BLOCK, winlock=True)
        self.assertEqual(out[0x0F], 1)
        self.assertEqual(bytes(out[:0x0F]) + bytes(out[0x10:]), m.TEMPLATE_LED_BLOCK[:0x0F] + m.TEMPLATE_LED_BLOCK[0x10:])
        self.assertEqual(m.patch_led_block(out, winlock=False), m.TEMPLATE_LED_BLOCK)


class OsMode(unittest.TestCase):
    """Byte 0x1b: observed 00 (Windows), 01 (Android, Fn+Q), 02 (Mac) on a real F75."""

    def test_decode(self):
        b = bytearray(m.TEMPLATE_LED_BLOCK)
        b[0x1B] = 0
        self.assertEqual(m.decode_led_block(bytes(b))["os_mode"], "windows")
        b[0x1B] = 2
        self.assertEqual(m.decode_led_block(bytes(b))["os_mode"], "mac")
        b[0x1B] = 1
        self.assertEqual(m.decode_led_block(bytes(b))["os_mode"], "android")
        b[0x1B] = 3
        self.assertEqual(m.decode_led_block(bytes(b))["os_mode"], "unknown")

    def test_patch(self):
        out = m.patch_led_block(m.TEMPLATE_LED_BLOCK, os_mode="mac")
        self.assertEqual(out[0x1B], 2)
        self.assertEqual(m.patch_led_block(out, os_mode="windows")[0x1B], 0)
        self.assertEqual(m.patch_led_block(out, os_mode="android")[0x1B], 1)
        with self.assertRaises(m.DeviceError):
            m.patch_led_block(m.TEMPLATE_LED_BLOCK, os_mode="linux")


class DongleStatus(unittest.TestCase):
    """Frames captured from a real F75 on its 2.4 GHz dongle."""

    def test_unsolicited_status(self):
        f = bytes.fromhex("13 0a 01 00 04 05 64 01 00 00 00 00 00 00 00 00 00 00 00 8c")
        self.assertEqual(m.wl_checksum(f), f[19])
        st = m.wl_parse_status(f)
        self.assertEqual((st["battery"], st["flag"], st["link_type"]), (100, 1, 1))
        self.assertFalse(st["charging"])

    def test_usb_power_reply_flags_charging(self):
        # 0x87 reply on the cable: 64 11 -> 100 %, flag 0x11 (bit 4 = charging)
        p = m.power_dict(0x64, 0x11, 0, "64 11")
        self.assertEqual(p["battery"], 100)
        self.assertTrue(p["charging"])

    def test_requested_status(self):
        f = bytes.fromhex("13 4a 01 00 02 64 01 00 00 00 00 00 00 00 00 00 00 00 00 c5")
        self.assertEqual(m.wl_checksum(f), f[19])
        self.assertEqual(m.wl_parse_status(f)["battery"], 100)
        self.assertEqual(m.wl_frame(m.WL_CMD_READ_STATUS, 1, 0, b"")[:5], bytes([0x13, 0x4a, 1, 0, 0]))

    def test_info_carries_model_password(self):
        f = bytes.fromhex("13 05 01 00 0a 03 00 00 00 00 cd 01 00 00 00 00 00 00 00 f4")
        self.assertEqual(m.wl_checksum(f), f[19])
        info = m.wl_parse_info(f)
        self.assertTrue(info["model_ok"])
        self.assertEqual(info["password"], m.MODEL_PASSWORD)

    def test_rejects_other_frames(self):
        self.assertIsNone(m.wl_parse_status(bytes.fromhex("13 44 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 58")))
        self.assertIsNone(m.wl_parse_status(b"\x05\xe9\x00"))
