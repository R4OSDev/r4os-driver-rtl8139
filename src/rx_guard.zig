const std = @import("std");

pub const persistent_sample_limit: u8 = 8;

pub fn headerValid(status: u16, len: u16) bool {
    return status != 0 and len >= 4 and len <= 1536 + 4 and (status & 1) != 0;
}

pub const Guard = struct {
    head: u16 = 0,
    status: u16 = 0,
    len: u16 = 0,
    samples: u8 = 0,

    pub fn reset(self: *Guard) void {
        self.* = .{};
    }

    pub fn observe(self: *Guard, head: u16, status: u16, len: u16) bool {
        if (headerValid(status, len)) {
            self.reset();
            return false;
        }
        if (self.samples != 0 and self.head == head and self.status == status and self.len == len) {
            if (self.samples < persistent_sample_limit) self.samples += 1;
        } else {
            self.head = head;
            self.status = status;
            self.len = len;
            self.samples = 1;
        }
        return self.samples >= persistent_sample_limit;
    }
};

test "unchanged invalid RX head triggers one bounded recovery decision" {
    var guard = Guard{};
    var sample: u8 = 1;
    while (sample < persistent_sample_limit) : (sample += 1) {
        try std.testing.expect(!guard.observe(64, 0, 0));
    }
    try std.testing.expect(guard.observe(64, 0, 0));
    try std.testing.expect(guard.observe(64, 0, 0));
}

test "progress or a valid header resets invalid-head evidence" {
    var guard = Guard{};
    try std.testing.expect(!guard.observe(64, 0, 0));
    try std.testing.expect(!guard.observe(68, 0, 0));
    try std.testing.expectEqual(@as(u8, 1), guard.samples);
    try std.testing.expect(!guard.observe(68, 1, 64));
    try std.testing.expectEqual(@as(u8, 0), guard.samples);
}

test "corrupt lengths are guarded like unpublished headers" {
    var guard = Guard{};
    var sample: u8 = 1;
    while (sample < persistent_sample_limit) : (sample += 1) {
        try std.testing.expect(!guard.observe(128, 1, 4096));
    }
    try std.testing.expect(guard.observe(128, 1, 4096));
}
