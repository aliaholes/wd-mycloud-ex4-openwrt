# WD My Cloud EX4: hardware map

Everything here was read from one unit on firmware 2.12.127 unless marked otherwise. "Unknown" means unknown.

## The board

| | |
|---|---|
| SoC | Marvell Kirkwood 88F6282 (stock dmesg: `MV88F6282-Rev-Unsupported`, TCLK 200 MHz), CPU Feroceon 88FR131 rev 1, ARMv5TE |
| RAM | 512 MiB |
| NAND | Samsung, 256 MiB, 2 KiB pages, 128 KiB blocks, on `orion_nand` |
| SATA | Marvell 88SX7042 (PCI 11ab:7042) on PCIe port 0, four ports = the four bays, driver `sata_mv` |
| USB 3 | Etron EJ168 xHCI (PCI 1b6f:7023, class 0c0330) on PCIe port 1 |
| Ethernet | two gigabit ports on the SoC's two MACs (`mv643xx_eth`), two Marvell 88E151x-class PHYs on one MDIO bus at addresses 0 and 1 (stock names: `egiga0`, `egiga1`, bonded as `bond0`) |
| UART0 | console, 115200 8N1 (header inside the case; we never opened it) |
| UART1 | the front-panel microcontroller, 19200 8N1: [MCU-PROTOCOL.md](MCU-PROTOCOL.md) |
| I2C | bus 0 is registered by stock; no client found |
| RTC | none that ticks on the SoC; the time is kept by the front-panel micro |
| Stock machine id | 527 (`Marvell xCat98DX Development Board`), cmdline `root=/dev/ram console=ttyS0,115200 max_loop=32 :::DB88FXX81:egiga0:none` |
| U-Boot | 1.1.4, `Marvell version: 3.5.9.LIGHTNING-4A.01`; environment block empty (all 0xFF) on the unit |

## Flash layout (WD's own names, offsets and numbering)

| mtd | Offset | Size | Name | Notes |
|---|---|---|---|---|
| 0 | 0x00000000 | 1 MiB | `u-boot` | |
| 1 | 0x00100000 | 5 MiB | `uImage` | stock kernel, a legacy uImage |
| 2 | 0x00600000 | 5 MiB | `ramdisk` | stock ramdisk (ext2 image in a uImage) |
| 3 | 0x00b00000 | 205 MiB | `image` | |
| 4 | **0x0dd00000** | 15 MiB | `rescue firmware` | its first good block holds the unit's identity |
| 5 | **0x0ec00000** | 20 MiB | `config` | UBI |
| 6 | **0x0d800000** | 5 MiB | `reserve` | UBI. It lies *below* mtd4 |

- **The numbering is not address order.** The table is the stock kernel's own boot log (`Creating 7 MTD partitions
  on "orion_nand"`), read again on the unit on Nov 17 2026. Our device tree had the last three in address order
  until run 7 (`rescue firmware` at 0x0d800000, `config` at 0x0e700000, `reserve` at 0x0fb00000): the sizes and
  names matched `/proc/mtd`, which shows no offsets, and nothing checked the offsets against stock. Under that
  tree the kernel's `rescue firmware` began with WD's `reserve` (a UBI volume), so the trial found no MAC address
  in it. Nothing was written through it: every partition was read-only. `tests/dtb_check.py --v6` now compares
  the compiled tree with the stock table, and `tests/flash-slice.py` shows on your own dumps what a tree hands out
  under each name.

- ECC: on dumps with OOB, WD's ECC bytes equal mainline Linux's 1-bit software Hamming code in the standard
  layout on every non-empty page checked (5,634 pages), so mainline's default software ECC reads this flash.
- The identity block (start of the first good block of mtd4): the two MAC addresses as text, `00:90:A9:xx:xx:xx`,
  at byte 0 and byte 0x1c; `55 AA` and the string `LigRescure` at 0x32. WD's `mac_read` gives the first to port 1
  and the second to port 2.

## Pins

MPP control registers under stock: `21111111 033b3311 33331100 33003333 00000033` (MPP_CTRL0..4).

| Pins | Function |
|---|---|
| MPP0-5, 18, 19 | NAND |
| MPP6 | SYSRST out |
| MPP8, 9 | TWSI0 (I2C) |
| MPP10, 11 | UART0 |
| MPP13, 14 | UART1 (front-panel micro) |
| MPP20-27, 30-33 | second gigabit MAC (GE1) |
| MPP7, MPP12 | set to a non-GPIO function by stock; use unknown |
| the rest | GPIO |

GPIO outputs as stock drives them at rest: 17=1, 28=0, 29=0, 34=1, 35=1, 36=1, 37=1, 38=1, 40=1, 45-48=0.
GPIO inputs: 15, 16, 39, 41, 42, 43, 44, 49.

| GPIO | What | How we know |
|---|---|---|
| 39 (in) | fan tachometer, two pulses per turn | WD's library, and **used on the unit** by `ex4fan` |
| 29 (out) | power LED, blue | WD's `led` under emulation (it writes SoC registers, not micro frames) |
| 28 (out) | power LED, red | same |
| 45 (out) | bay 1 LED, red | same; 46, 47, 48 for bays 2 to 4 are inferred, not seen |
| (SATA controller register) | bay LEDs, blue | same: `led hd0 blue on` writes the 88SX7042's own GPIO register |
| 17, 34-38, 40 (out, high) | unknown: USB port power and bay power are probably among them | not mapped |
| 15, 16, 41-44, 49 (in) | unknown | not mapped |

LED polarity has not been seen on the unit. The buttons are not GPIOs: they arrive as frames from the micro.
The LCD is driven through the micro; its frames are not decoded.

## Under Linux 6.12.112 (OpenWrt 25.12.6 kirkwood) on the unit

- Works with `dts/kirkwood-wd-mycloud-ex4.dts`: both UARTs, NAND (read-only in the trial tree), both PCIe ports,
  `sata_mv` with four disks, both MACs and PHYs, the orion watchdog, the SoC thermal sensor, CESA crypto, GPIO.
- Up to run 7 `hwmon0`/`hwmon1` were the two PHYs' temperature sensors (run 7: `f1072004.mdio-bus-mii:00` 28 °C,
  `:01` 46 °C), registered by the Marvell PHY driver. With the generic PHY driver (below) they are gone.
- With the overlay's modules `xhci_hcd` binds the EJ168 and a SuperSpeed root hub comes up (run 7). The image we
  boot has no xhci module of its own.
- The device tree describes no LEDs, buttons, fan or bay power, and claims none of those pins.
- There is no usb-storage module in the trial, on purpose for now: `ex4fan` already leaves USB disks out of its
  drive list, but the self-test's bay count and `ex4log`'s choice of a log disk were written for a system where
  every `sd*` is a SATA bay. Whoever adds usb-storage has to teach those two first.

## The link flap

**Seen** (runs 5, 6, 7, under the Marvell PHY driver): on the cabled port the kernel logs `link down` and, 6 ms
later, `link up, 1000 Mb/s, full duplex`, once every 1.04 s, for as long as the system runs. Run 7: 2329 carrier
changes in 1237 s of uptime, about 113 a minute; the port without a cable: 0. `mv643xx_eth` throws its transmit
queue away at each `link down`. Under WD's 3.2.40 kernel the same port, cable and switch show three `link down`
lines in the whole log, all from bringing the interface up.

**Cause** (read in Linux 6.12.112's source; `tests/phy-id-check.py` re-checks each of these lines):

1. The two PHYs answer to Linux's "Marvell 88E1510" driver entry (the 88E1510/1512/1514/1518 family, id
   `0141.0ddx`). Run 8 read the id registers with `ex4phy`: both PHYs answer `0141.0dd1` on register page 0
   ([RUNS.md](RUNS.md), run 8). Before that read, the evidence was the driver's own temperature sensor on each PHY with
   whole-degree readings that are not multiples of 5 (the 88E151x sensor; the older 88E1121 one steps by 5 °C), and
   WD's kernel carrying an init routine for the 88E1512.
2. That driver entry declares fibre support, and its `marvell_read_status()` therefore selects the PHY's **fibre**
   register page (page 1) on every poll, reads the fibre link state (down: nothing is connected there), and
   switches back to the copper page (page 0). phylib polls once a second.
3. The Kirkwood MAC does not get its link state from phylib. While the PHY autonegotiates, `mv643xx_eth` leaves
   the MAC's own hardware negotiation on: the MAC polls the PHY's registers over the same MDIO bus by itself and
   raises a link interrupt when what it reads changes. In the window where the page register says "fibre" it
   reads the fibre page's status, link down, and a moment later the copper page's, link up. `link down` and
   `link up` in the log come from that interrupt (`handle_link_event`), not from phylib.

**Fix in this tree** (device tree only; the kernel is still OpenWrt's official binary): each PHY node carries
`compatible = "ethernet-phy-id0141.0000"` first. The kernel takes a PHY's id from that string instead of reading
the chip, no PHY driver claims that id, and the PHY falls to the kernel's built-in generic driver, which never
writes the page register. `0141` is Marvell's vendor number; model 0 is deliberately not a real part.

**What that costs:** the PHY temperature sensors; the Marvell driver's set-up of RGMII delays, LED modes and
downshift. The PHY keeps what the previous stage programmed (U-Boot at power-on, and the stock system before a RAM
trial), which is what stock itself runs with.

**What would be better:** a kernel change, so the Marvell driver can stay: either `mv643xx_eth` forcing link,
speed and duplex into the MAC from phylib's result instead of leaving hardware negotiation on (what `mvneta` does
for the same MAC family), or the Marvell driver not visiting the fibre page of a PHY whose fibre side is not wired.
We did not build a kernel: this release boots OpenWrt's own.

## Still unmapped (help wanted)

LED polarity and GPIO 46-48; which outputs power the USB ports and the bays; the seven unknown inputs; the LCD
frames; which button press sends `PWR` versus `PWR2`; whether the micro keeps the fan speed when nobody talks to
it. (The PHYs' id was read in run 8: `0141.0dd1`, see "The link flap" above.)
