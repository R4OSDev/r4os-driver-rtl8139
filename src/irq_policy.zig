pub const rx_ok: u16 = 1 << 0;
pub const rx_error: u16 = 1 << 1;
pub const tx_ok: u16 = 1 << 2;
pub const tx_error: u16 = 1 << 3;
pub const rx_overflow: u16 = 1 << 4;
pub const packet_underrun: u16 = 1 << 5;

pub const active_mask: u16 = rx_ok | rx_error | tx_ok | tx_error | rx_overflow | packet_underrun;
// TSD reclaim is lazy; keep TX_OK in the acknowledged status, but do not
// raise an interrupt for a successful send. All error causes stay enabled.
pub const interrupt_mask: u16 = active_mask & ~tx_ok;
pub const rx_mask: u16 = rx_ok | rx_error | rx_overflow | packet_underrun;
pub const invalid_mask: u16 = rx_error | rx_overflow | packet_underrun;

pub fn hasRxWork(raw_isr: u16) bool {
    return (raw_isr & rx_mask) != 0;
}

pub fn hasInvalidRx(raw_isr: u16) bool {
    return (raw_isr & invalid_mask) != 0;
}

pub fn hasRxOverflow(raw_isr: u16) bool {
    return (raw_isr & rx_overflow) != 0;
}

test "TX-only causes never schedule RX" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u16, 0x003B), interrupt_mask);
    try std.testing.expect(!hasRxWork(tx_ok));
    try std.testing.expect(!hasRxWork(tx_error));
    try std.testing.expect(!hasRxWork(tx_ok | tx_error));
}

test "RX and mixed causes schedule exactly one RX handoff" {
    const std = @import("std");
    try std.testing.expect(hasRxWork(rx_ok));
    try std.testing.expect(hasRxWork(rx_error | tx_ok));
    try std.testing.expect(hasInvalidRx(rx_overflow | tx_error));
    try std.testing.expect(hasRxOverflow(rx_overflow));
}
