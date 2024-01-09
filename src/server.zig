const std = @import("std");
const shared = @import("./shared.zig");

const AF_LOCAL = shared.c.AF_LOCAL;
const O_CREAT = shared.c.O_CREAT;
const O_EXCL = shared.c.O_EXCL;
const O_RDWR = shared.c.O_RDWR;
const PF_LOCAL = shared.c.PF_LOCAL;
const PROT_READ = shared.c.PROT_READ;
const PROT_WRITE = shared.c.PROT_WRITE;
const SCM_RIGHTS = shared.c.SCM_RIGHTS;
const SO_PEERCRED = shared.c.SO_PEERCRED;
const SOCK_STREAM = shared.c.SOCK_STREAM;
const SOL_SOCKET = shared.c.SOL_SOCKET;
const fd_t = std.c.fd_t;
const socklen_t = std.c.socklen_t;
const struct_cmsghdr = shared.c.struct_cmsghdr;
const struct_msghdr = shared.c.struct_msghdr;
const struct_iovec = shared.c.struct_iovec;
const struct_sockaddr_un = shared.c.struct_sockaddr_un;
const struct_ucred = shared.c.struct_ucred;
const CMSG_DATA = shared.c.CMSG_DATA;
const CMSG_FIRSTHDR = shared.c.CMSG_FIRSTHDR;
const CMSG_LEN = shared.c.CMSG_LEN;
const CMSG_SPACE = shared.c.CMSG_SPACE;

const SHMEM_PATH = shared.SHMEM_PATH;
const SOCKET_PATH = shared.SOCKET_PATH;
const ShmemStruct = shared.ShmemStruct;
const strerrno = shared.strerrno;

var socket_fd: fd_t = -1;
var client_fd: fd_t = -1;
var shmem_fd: fd_t = -1;
var shmem_ptr: ?*ShmemStruct = null;

fn createShmem() !void {
    // Best-effort remove the shmem file in case it wasn't cleaned up previously.
    _ = std.c.shm_unlink(SHMEM_PATH);

    shmem_fd = std.c.shm_open(
        SHMEM_PATH,
        O_CREAT | O_EXCL | O_RDWR,
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
    if (std.c.shm_unlink(SHMEM_PATH) < 0) {
        shared.warn(
            "Failed to unlink the shmem file '{s}': {s}",
            .{ SHMEM_PATH, strerrno() },
        );
    }

    if (std.c.ftruncate(shmem_fd, @sizeOf(ShmemStruct)) < 0) {
        return error.ftruncate;
    }

    // Map the object into the caller's address space.
    const mmap_result = std.c.mmap(
        null,
        @sizeOf(ShmemStruct),
        PROT_READ | PROT_WRITE,
        shared.c.MAP_SHARED,
        shmem_fd,
        0,
    );
    if (mmap_result == shared.c.MAP_FAILED) {
        return error.mmap;
    }
    shmem_ptr = @alignCast(@ptrCast(mmap_result));

    // Initialize semaphores as process-shared, with value 0.
    if (std.c.sem_init(@ptrCast(&shmem_ptr.?.sem1), 1, 0) == -1) {
        return error.sem_init_sem1;
    }
    if (std.c.sem_init(@ptrCast(&shmem_ptr.?.sem2), 1, 0) == -1) {
        return error.sem_init_sem2;
    }
}

fn createSocket() !void {
    const sockaddr: struct_sockaddr_un = shared.getSockaddr();

    // Create the socket.
    shared.debug("Creating socket", .{});
    socket_fd = std.c.socket(PF_LOCAL, SOCK_STREAM, 0);
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

    if (std.c.bind(
        socket_fd,
        @ptrCast(&sockaddr),
        @sizeOf(@TypeOf(sockaddr)),
    ) != 0) {
        shared.err("bind({s}) failed: {s}", .{ sockaddr.sun_path, strerrno() });
        return error.socket_bind;
    }
}

fn socketWaitForClient() !fd_t {
    if (std.c.listen(socket_fd, 1) != 0) {
        shared.err("listen() failed: {s}", .{strerrno()});
        return error.socket_listen;
    }

    shared.debug("Listening on socket, waiting for client to connect...", .{});

    const fd = std.c.accept(socket_fd, null, null);
    if (fd == -1) {
        shared.err("accept() failed: {s}", .{strerrno()});
        return error.socket_accept;
    }

    shared.debug("Client connected, fd={d}", .{fd});

    return (fd);
}

fn getClientInfo(fd: fd_t) !void {
    var ucred: struct_ucred = undefined;
    var len: socklen_t = @sizeOf(@TypeOf(ucred));

    if (std.c.getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &ucred, &len) < 0) {
        shared.err("getsockopt() failed: {s}", .{strerrno()});
        return error.getsockopt;
    }

    shared.debug(
        "Client PID={d}, UID={d}, GID={d}",
        .{ ucred.pid, ucred.uid, ucred.gid },
    );
}

/// Based on the example at https://man7.org/linux/man-pages/man3/cmsg.3.html
fn sendShmemFd() !void {
    var data: c_int = 42;
    var msg: struct_msghdr = undefined;
    var iov: struct_iovec = undefined;
    var cmsg: struct_cmsghdr = undefined;

    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    iov.iov_base = &data;
    iov.iov_len = @sizeOf(@TypeOf(data));
    msg.msg_control = &cmsg;
    msg.msg_controllen = @sizeOf(@TypeOf(cmsg));
    cmsg.cmsg_level = SOL_SOCKET;
    cmsg.cmsg_type = SCM_RIGHTS;
    cmsg.cmsg_len = CMSG_LEN(@sizeOf(@TypeOf(shmem_fd)));
    // Not sure why CMSG_DATA() fails to find the __cmsg_data() method...
    // @memcpy(CMSG_DATA(&cmsg), &shmem_fd);
    // @memcpy(@as([*]u8, @ptrCast(cmsg.__cmsg_data())), &[_]fd_t{shmem_fd});
    std.mem.copyForwards(
        fd_t,
        @as(&[1]fd_t, @alignCast(@ptrCast(cmsg.__cmsg_data()))),
        &[_]fd_t{shmem_fd},
    );

    // Send fd plus ancillary data.
    if (std.c.sendmsg(client_fd, &msg, 0) < 0) {
        shared.err("sendmsg() failed: {s}", .{strerrno()});
        return error.sendmsg;
    }
}

pub fn main() !void {
    std.debug.print("Server starting...\n", .{});

    try createShmem();

    try createSocket();

    client_fd = try socketWaitForClient();

    getClientInfo(client_fd) catch {};

    try sendShmemFd();

    shared.pause();
}
