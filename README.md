# dtb.zig

Parse device tree blob files.

```zig
var qemu = try dtb.parse(std.testing.allocator, qemu_dtb);
defer qemu.deinit(std.testing.allocator);
```

## regs and strings

```zig
// This QEMU DTB places 512MiB of memory at 1GiB.
testing.expectEqualSlices(
    [2]u64,
    &.{.{ 1024 * 1024 * 1024, 512 * 1024 * 1024 }},
    qemu.propAt(&.{"memory@40000000"}, .Reg).?,
);

// It has an A53-compatible CPU.
const compatible = qemu.propAt(&.{ "cpus", "cpu@0" }, .Compatible).?;
testing.expectEqual(@as(usize, 1), compatible.len);
testing.expectEqualStrings("arm,cortex-a53", compatible[0]);
```

## interrupts and clocks

```zig
const pl011 = qemu.child("pl011@9000000").?;

// Its pl011 UART controller has one SPI-type interrupt, IRQ 1, active high
// level-sensitive. See https://git.io/JtKJk.
const interrupts = pl011.prop(.Interrupts).?;
testing.expectEqual(@as(usize, 1), interrupts.len);
testing.expectEqualSlices(u32, &.{ 0x0, 0x01, 0x04 }, interrupts[0]);

// It defines two clocks named uartclk and apb_pclk, both referring to the
// APB's main system clock PCLK at handle 0x8000.
const clock_names = pl011.prop(.ClockNames).?;
testing.expectEqual(@as(usize, 2), clock_names.len);
testing.expectEqualSlices(u8, "uartclk", clock_names[0]);
testing.expectEqualSlices(u8, "apb_pclk", clock_names[1]);
const clocks = pl011.prop(.Clocks).?;
testing.expectEqual(@as(usize, 2), clocks.len);
testing.expectEqualSlices(u32, &.{0x8000}, clocks[0]);
testing.expectEqualSlices(u32, &.{0x8000}, clocks[1]);
```

## notes, incomplete

Still many prop types are just left unparsed. Please add them as you go! Merge requests happily accepted.

Ranges are `u128`s because a PCIe bus has an `#address-cells` of 3? What's with that?

## LICENSE

MIT, per [Zig](https://github.com/ziglang/zig).
