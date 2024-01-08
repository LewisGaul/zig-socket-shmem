const std = @import("std");

const c = @cImport({
    @cInclude("errno.h"); // errno, E* constants, e.g. EBADFD
    @cInclude("fcntl.h"); // O_* constants, e.g. O_CREAT
    @cInclude("semaphore.h"); // sem_*(), sem_t
    @cInclude("sys/mman.h"); // Memory MANagement - shm_*(), mmap(), ...
    @cInclude("sys/socket.h"); // struct sockaddr, bind(), accept(), listen()
    @cInclude("sys/un.h"); // struct sockaddr_un
    @cInclude("unistd.h"); // ftruncate()
});

const shared = @import("./shared.zig");
const SHMEM_PATH = shared.SHMEM_PATH;
const SOCKET_PATH = shared.SOCKET_PATH;
const ShmemStruct = shared.ShmemStruct;
const strerrno = shared.strerrno;

var socket_fd: c_int = -1;
var client_fd: c_int = -1;
var shmem_fd: c_int = -1;
var shmem_ptr: ?*ShmemStruct = null;

fn createShmem() !void {
    // Best-effort remove the shmem file in case it wasn't cleaned up previously.
    _ = c.shm_unlink(SHMEM_PATH);

    shmem_fd = c.shm_open(
        SHMEM_PATH,
        c.O_CREAT | c.O_EXCL | c.O_RDWR,
        0x700,
    );
    if (shmem_fd < 0) {
        shared.err(
            "Unable to create shared memory object: {s}",
            .{strerrno()},
        );
        return error.shm_open;
    }

    // Now that we have a fd, we no longer need an entry in the filesystem.
    shared.debug("Unlinking shared memory from filesystem", .{});
    if (c.shm_unlink(SHMEM_PATH) < 0) {
        shared.warn(
            "Failed to unlink the shmem file '{s}': {s}",
            .{ SHMEM_PATH, strerrno() },
        );
    }

    if (c.ftruncate(shmem_fd, @sizeOf(ShmemStruct)) < 0) {
        return error.ftruncate;
    }

    // Map the object into the caller's address space.
    const mmap_result = c.mmap(
        null,
        @sizeOf(ShmemStruct),
        c.PROT_READ | c.PROT_WRITE,
        c.MAP_SHARED,
        shmem_fd,
        0,
    );
    if (mmap_result == null or mmap_result == c.MAP_FAILED) {
        return error.mmap;
    }
    shmem_ptr = @alignCast(@ptrCast(mmap_result));

    // Initialize semaphores as process-shared, with value 0.
    if (c.sem_init(@ptrCast(&shmem_ptr.?.sem1), 1, 0) == -1) {
        return error.sem_init_sem1;
    }
    if (c.sem_init(@ptrCast(&shmem_ptr.?.sem2), 1, 0) == -1) {
        return error.sem_init_sem2;
    }
}

fn createSocket() !void {
    const sockaddr: c.struct_sockaddr_un = addr: {
        var tmp_sockaddr = c.struct_sockaddr_un{
            .sun_family = c.AF_LOCAL,
            .sun_path = undefined,
        };
        @memset(&tmp_sockaddr.sun_path, 0);
        @memcpy(tmp_sockaddr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);
        break :addr tmp_sockaddr;
    };

    // Create the socket.
    shared.debug("Creating socket", .{});
    socket_fd = c.socket(c.PF_LOCAL, c.SOCK_STREAM, 0);
    if (socket_fd == -1) {
        shared.err("socket() failed: {s}", .{strerrno()});
        return error.socket_create;
    }
    shared.debug("Socket fd={d}", .{socket_fd});

    // Make the socket non-blocking so that we can select() on it. Or more
    // specifically, if we don't do this then there's a chance that the
    // accept() we call after getting a read event from select may block
    // indefinitely.
    //fd_set_flags(socket_fd, O_NONBLOCK);

    if (c.bind(socket_fd, @ptrCast(&sockaddr), @sizeOf(@TypeOf(sockaddr))) != 0) {
        shared.err("bind({s}) failed: {s}", .{ sockaddr.sun_path, strerrno() });
        return error.socket_bind;
    }
}

pub fn main() !void {
    std.debug.print("Server starting...\n", .{});

    try createShmem();

    try createSocket();
}
