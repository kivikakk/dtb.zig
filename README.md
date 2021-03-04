# dtb.zig

Parse device tree blob files.

```zig
var qemu_arm64 = try dtb.parse(std.testing.allocator, qemu_arm64_dtb);
defer qemu_arm64.deinit(std.testing.allocator);
```

## regs and strings

```zig
// This QEMU DTB places 512MiB of memory at 1GiB.
testing.expectEqualSlices(
    [2]u64,
    &.{.{ 1024 * 1024 * 1024, 512 * 1024 * 1024 }},
    qemu_arm64.propAt(&.{"memory@40000000"}, .Reg).?,
);

// It has an A53-compatible CPU.
const compatible = qemu_arm64.propAt(&.{ "cpus", "cpu@0" }, .Compatible).?;
testing.expectEqual(@as(usize, 1), compatible.len);
testing.expectEqualStrings("arm,cortex-a53", compatible[0]);
```

## interrupts and clocks

```zig
const pl011 = qemu_arm64.child("pl011@9000000").?;

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

## no heap? no problem

The `Traverser` type is used internally by the parser, and you can use it too.

```zig
var qemu_arm64: Traverser = undefined;
try qemu_arm64.init(qemu_arm64_dtb);

var state: enum { OutsidePl011, InsidePl011 } = .OutsidePl011;
var ev = try qemu_arm64.current();

var reg_value: ?[]const u8 = null;

while (ev != .End) : (ev = try qemu_arm64.next()) {
    switch (state) {
        .OutsidePl011 => if (ev == .BeginNode and std.mem.startsWith(u8, ev.BeginNode, "pl011@")) {
            state = .InsidePl011;
        },
        .InsidePl011 => switch (ev) {
            .EndNode => state = .OutsidePl011,
            .Prop => |prop| if (std.mem.eql(u8, prop.name, "reg")) {
                reg_value = prop.value;
            },
            else => {},
        },
    }
}

std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0 }, reg_value.?);
```

## notes, incomplete

Still many prop types are just left unparsed. Please add them as you go! Merge requests happily accepted.

Ranges are `u128`s because a PCIe bus has an `#address-cells` of 3? What's with that?

## LICENSE

MIT, per [Zig](https://github.com/ziglang/zig).
