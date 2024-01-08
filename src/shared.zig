const std = @import("std");

const c = @cImport({
    @cInclude("semaphore.h"); // sem_t
    @cInclude("stdio.h"); // getchar()
    @cInclude("string.h"); // strerror()
    @cInclude("sys/types.h"); // size_t
});

// Maximum size for exchanged string.
pub const MAX_SHARED_STRING_LEN = 1024;

const USE_ABSTRACT_SOCKET = false;
pub const SOCKET_PATH = (if (USE_ABSTRACT_SOCKET) "\x00" else "") ++ "1234-socket";
pub const SHMEM_PATH = "/1234-shmem";
pub const SHM_SIZE_BYTES = 128 * 1024 * 1024;

pub const ShmemStruct = struct {
    sem1: c.sem_t, // POSIX unnamed semaphore
    sem2: c.sem_t, // POSIX unnamed semaphore
    count: usize, // Number of bytes used in 'buf'
    buf: [MAX_SHARED_STRING_LEN]u8, // Data being transferred
};

pub fn pause() void {
    std.debug.print("Press enter to continue...\n");
    // Requires very recent version of Zig, see
    // https://github.com/ziglang/zig/commit/8ce33795.
    // std.os.linux.pause();
    c.getchar();
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("DEBUG: " ++ fmt ++ "\n", args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("WARN:  " ++ fmt ++ "\n", args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("ERROR: " ++ fmt ++ "\n", args);
}

pub fn panic(comptime fmt: []const u8, args: anytype) void {
    err(fmt, args);
    std.debug.print("Exiting...\n", .{});
    std.process.exit(1);
}

pub fn strerrno() [*c]const u8{
    return c.strerror(std.c._errno().*);
}
