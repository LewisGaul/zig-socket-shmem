const std = @import("std");
const shared = @import("./shared.zig");

const F_DUPFD = shared.c.F_DUPFD;
const PF_LOCAL = shared.c.PF_LOCAL;
const SOCK_STREAM = shared.c.SOCK_STREAM;
const fd_t = std.c.fd_t;
const socklen_t = std.c.socklen_t;
const struct_sockaddr_un = shared.c.struct_sockaddr_un;

const SHMEM_PATH = shared.SHMEM_PATH;
const SOCKET_PATH = shared.SOCKET_PATH;
const ShmemStruct = shared.ShmemStruct;
const strerrno = shared.strerrno;

var socket_fd: fd_t = -1;
var shm_fd: fd_t = -1;
var shm_ptr: ?*ShmemStruct = null;

fn connectSocket() !fd_t {
    const sockaddr: struct_sockaddr_un = shared.getSockaddr();

    // Open the socket.
    const tmpfd = std.c.socket(PF_LOCAL, SOCK_STREAM, 0);
    if (tmpfd == -1) {
        shared.err("socket() failed: {s}", .{strerrno()});
        return error.socket_create;
    }

    // Re-map the socket FD so that it's high-numbered, and out of the way.
    const fd = std.c.fcntl(tmpfd, F_DUPFD, @as(c_int, 500));
    if (fd == -1) {
        shared.err("fcntl(F_DUPFD) failed: {s}", .{strerrno()});
        return error.fcntl_dupfd;
    }
    _ = std.c.close(tmpfd);

    // Connect to the server side.
    if (std.c.connect(fd, @ptrCast(&sockaddr), @sizeOf(@TypeOf(sockaddr))) != 0) {
        shared.err("connect({s}) failed: {s}", .{ sockaddr.sun_path, strerrno() });
        return error.socket_connect;
    }

    shared.debug("Connected to socket with fd {d}", .{fd});

    return fd;
}

pub fn main() !void {
    std.debug.print("Client starting...\n", .{});
    socket_fd = try connectSocket();

    shared.pause();
}
