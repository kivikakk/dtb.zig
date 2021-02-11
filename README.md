# dtb.zig

Parse device tree blob files.

```zig
var qemu = try dtb.parse(std.testing.allocator, qemu_dtb);
defer qemu.deinit(std.testing.allocator);

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

// Its pl011 UART controller has one SPI-type interrupt, IRQ 1, active high
// level-sensitive. See https://git.io/JtKJk.
const interrupts = qemu.propAt(&.{"pl011@9000000"}, .Interrupts).?;
testing.expectEqual(@as(usize, 1), interrupts.len);
testing.expectEqualSlices(u32, &.{ 0x0, 0x01, 0x04 }, interrupts[0]);
```

## Incomplete

Most prop types are just left unparsed. Please add them as you go! Merge requests happily accepted.

## LICENSE

MIT, per [Zig](https://github.com/ziglang/zig).
