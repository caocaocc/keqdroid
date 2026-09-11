#import "KEQXPC.h"
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <xpc/xpc.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <dirent.h>
#include <grp.h>
#include <libproc.h>
#include <poll.h>
#include <net/if.h>
#include <net/route.h>
#include <sys/sysctl.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>

static const char *serviceName = "io.github.caocaocc.keqdroid.network-service";
// Use the system-owned administrator right. A custom right may have been
// pre-created with an insecure "allow" rule before our installer ever runs.
static const char *authorizationRight = kAuthorizationRightExecute;
static const char *transportError = "{\"ok\":false,\"error\":{\"code\":\"serviceUnavailable\",\"message\":\"Network service is unavailable. Install or repair KEQDIS.pkg.\"}}";

@interface KEQConnection : NSObject
@property(nonatomic, strong) xpc_connection_t connection;
@property(nonatomic, strong) dispatch_queue_t queue;
@end
@implementation KEQConnection
@end

void *keq_client_create(void) {
    KEQConnection *client = [KEQConnection new];
    client.queue = dispatch_queue_create("io.github.caocaocc.keqdroid.client", DISPATCH_QUEUE_SERIAL);
    client.connection = xpc_connection_create_mach_service(serviceName, client.queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!client.connection) return NULL;
    xpc_connection_set_event_handler(client.connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(client.connection);
    return (__bridge_retained void *)client;
}
void keq_client_destroy(void *opaque) {
    if (!opaque) return;
    KEQConnection *client = CFBridgingRelease(opaque);
    xpc_connection_cancel(client.connection);
}
void keq_client_call(void *opaque, const char *json, keq_reply_callback callback, void *context) {
    if (!opaque) { callback(transportError, context); return; }
    KEQConnection *client = (__bridge KEQConnection *)opaque;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "json", json);
    __block BOOL completed = NO;
    dispatch_async(client.queue, ^{
        xpc_connection_send_message_with_reply(client.connection, request, client.queue, ^(xpc_object_t reply) {
            if (completed) return;
            completed = YES;
            const char *response = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_string(reply, "json") : NULL;
            callback(response ?: transportError, context);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), client.queue, ^{
            if (completed) return;
            completed = YES;
            callback("{\"ok\":false,\"error\":{\"code\":\"timeout\",\"message\":\"Network service request timed out.\"}}", context);
        });
    });
}

int keq_authorization_check_right(void) {
    CFDictionaryRef existing = NULL;
    OSStatus status = AuthorizationRightGet(authorizationRight, &existing);
    if (existing) CFRelease(existing);
    return (int)status;
}
int keq_authorization_external(unsigned char *bytes, size_t length, void **authorization) {
    if (length != sizeof(AuthorizationExternalForm) || !authorization) return (int)errAuthorizationInvalidPointer;
    *authorization = NULL;
    AuthorizationRef auth = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &auth);
    if (status) return (int)status;
    AuthorizationItem item = {authorizationRight, 0, NULL, 0};
    AuthorizationRights rights = {1, &item};
    status = AuthorizationCopyRights(auth, &rights, kAuthorizationEmptyEnvironment,
        kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize, NULL);
    if (!status) status = AuthorizationMakeExternalForm(auth, (AuthorizationExternalForm *)bytes);
    if (!status) *authorization = (void *)auth;
    else AuthorizationFree(auth, kAuthorizationFlagDefaults);
    return (int)status;
}
void keq_authorization_release(void *authorization) {
    if (authorization) AuthorizationFree((AuthorizationRef)authorization, kAuthorizationFlagDefaults);
}
int keq_authorization_validate(const unsigned char *bytes, size_t length) {
    if (length != sizeof(AuthorizationExternalForm)) return (int)errAuthorizationInvalidPointer;
    AuthorizationExternalForm external;
    memcpy(&external, bytes, sizeof(external));
    AuthorizationRef auth = NULL;
    OSStatus status = AuthorizationCreateFromExternalForm(&external, &auth);
    if (status) return (int)status;
    AuthorizationItem item = {authorizationRight, 0, NULL, 0};
    AuthorizationRights rights = {1, &item};
    // No interaction in root daemon; the GUI must already have obtained the right.
    status = AuthorizationCopyRights(auth, &rights, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, NULL);
    AuthorizationFree(auth, kAuthorizationFlagDefaults);
    return (int)status;
}

int keq_validate_code(const char *path, const char *requirement, int nested) {
    NSURL *url = [NSURL fileURLWithPath:@(path)];
    SecStaticCodeRef code = NULL;
    SecRequirementRef req = NULL;
    OSStatus result = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
    if (!result && requirement && requirement[0]) result = SecRequirementCreateWithString((__bridge CFStringRef)@(requirement), kSecCSDefaultFlags, &req);
    if (!result) result = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckAllArchitectures | (nested ? kSecCSCheckNestedCode : 0), req);
    if (req) CFRelease(req);
    if (code) CFRelease(code);
    return (int)result;
}
static BOOL trustedApp(xpc_object_t message, const char *appPath, const char *requirement, BOOL fullValidation) {
    SecCodeRef guest = NULL;
    SecRequirementRef req = NULL;
    CFURLRef codeURL = NULL;
    OSStatus result = SecCodeCreateWithXPCMessage(message, kSecCSDefaultFlags, &guest);
    if (!result) result = SecRequirementCreateWithString((__bridge CFStringRef)@(requirement), kSecCSDefaultFlags, &req);
    if (!result) result = SecCodeCheckValidity(guest, kSecCSDefaultFlags, req);
    if (!result) result = SecCodeCopyPath(guest, kSecCSDefaultFlags, &codeURL);
    NSString *actual = codeURL ? [(__bridge NSURL *)codeURL path] : nil;
    NSString *expected = @(appPath);
    BOOL pathMatches = [actual isEqualToString:expected] || [actual hasPrefix:[expected stringByAppendingString:@"/Contents/MacOS/"]];
    struct stat st;
    BOOL owned = lstat(appPath, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == 0 && !(st.st_mode & 0022);
    // The ad-hoc app may contain frameworks with symlinks. Every resolved item
    // must stay in the bundle and be root-owned, not merely the top directory.
    if (owned && fullValidation) {
        __block BOOL enumerationFailed = NO;
        NSDirectoryEnumerator *items = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:expected]
            includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { (void)url; (void)error; enumerationFailed = YES; return NO; }];
        for (NSURL *item in items) {
            NSString *resolved = item.URLByResolvingSymlinksInPath.path;
            if (![resolved hasPrefix:[expected stringByAppendingString:@"/"]] || stat(resolved.fileSystemRepresentation, &st) != 0 || st.st_uid != 0 || (st.st_mode & 0022) || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode))) { owned = NO; break; }
        }
        if (!items || enumerationFailed) owned = NO;
    }
    if (codeURL) CFRelease(codeURL);
    if (req) CFRelease(req);
    if (guest) CFRelease(guest);
    return result == 0 && pathMatches && owned && (!fullValidation || keq_validate_code(appPath, requirement, 1) == 0);
}
@interface KEQReply : NSObject
@property(nonatomic, strong) xpc_object_t message;
@property(nonatomic, strong) xpc_connection_t connection;
@end
@implementation KEQReply
@end
void keq_server_reply(void *opaque, const char *json) {
    if (!opaque) return;
    KEQReply *reply = CFBridgingRelease(opaque);
    xpc_object_t response = xpc_dictionary_create_reply(reply.message);
    if (!response) return;
    xpc_dictionary_set_string(response, "json", json);
    xpc_connection_send_message(reply.connection, response);
}
int keq_server_start(const char *requirement, const char *app_path, keq_request_callback callback, void *context) {
    NSString *req = @(requirement), *app = @(app_path);
    dispatch_queue_t queue = dispatch_queue_create("io.github.caocaocc.keqdroid.server", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create_mach_service(serviceName, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) return -1;
    int result = xpc_connection_set_peer_code_signing_requirement(listener, req.UTF8String);
    if (result) return result;
    __block uint64_t nextID = 0;
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        uint64_t clientID = ++nextID;
        uid_t uid = xpc_connection_get_euid(peer);
        gid_t gid = xpc_connection_get_egid(peer);
        __block BOOL validatedBundle = NO;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                callback("{\"method\":\"clientDisconnected\",\"arguments\":{}}", uid, gid, clientID, NULL, context);
                return;
            }
            if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
            KEQReply *reply = [KEQReply new]; reply.message = event; reply.connection = peer;
            void *replyHandle = (__bridge_retained void *)reply;
            const char *json = xpc_dictionary_get_string(event, "json");
            if (!json || strnlen(json, 4 * 1024 * 1024 + 1) > 4 * 1024 * 1024 || !trustedApp(event, app.UTF8String, req.UTF8String, !validatedBundle)) {
                keq_server_reply(replyHandle, "{\"ok\":false,\"error\":{\"code\":\"untrustedClient\",\"message\":\"Install the matching KEQDIS application package.\"}}");
                return;
            }
            // The root-owned bundle cannot change through an unprivileged
            // client; cache expensive resource verification for this connection.
            // XPC and SecCode still validate the message sender on every call.
            validatedBundle = YES;
            callback(json, uid, gid, clientID, replyHandle, context);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
    // launchd owns the lifetime of this daemon. Keep listener alive until process exit.
    (void)CFBridgingRetain(listener);
    return 0;
}

uint64_t keq_process_start_time(pid_t pid) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec;
}

static int ipv4RoutePrefix(const unsigned char *bytes, size_t length, const struct rt_msghdr *header) {
    if (header->rtm_flags & RTF_HOST) return 32;
    size_t offset = sizeof(*header);
    for (int index = 0; index < RTAX_MAX; ++index) {
        if (!(header->rtm_addrs & (1 << index))) continue;
        if (offset + 2 > length) return -1;
        size_t addressLength = bytes[offset];
        size_t alignedLength = addressLength ? (addressLength + 3) & ~3 : 4;
        if (offset + alignedLength > length) return -1;
        if (index == RTAX_NETMASK) {
            unsigned char mask[4] = {0};
            size_t start = offsetof(struct sockaddr_in, sin_addr);
            if (addressLength > start) memcpy(mask, bytes + offset + start, MIN(sizeof(mask), addressLength - start));
            int prefix = 0, zeroSeen = 0;
            for (int bit = 0; bit < 32; ++bit) {
                if (mask[bit / 8] & (0x80 >> (bit % 8))) {
                    if (zeroSeen) return -1;
                    ++prefix;
                } else zeroSeen = 1;
            }
            return prefix;
        }
        offset += alignedLength;
    }
    return -1;
}

static int routeLookup(int family, const char *address, int prefix, struct rt_msghdr *found) {
    // Darwin requires 32-bit sockaddr alignment. Both IPv4 (16 bytes) and
    // IPv6 (28 bytes) already satisfy it; omit unused bytes from the request.
    struct { struct rt_msghdr header; unsigned char addresses[56]; } request = {0};
    size_t destinationSize;
    if (family == AF_INET) {
        struct sockaddr_in destination = {0};
        destination.sin_len = sizeof(destination); destination.sin_family = AF_INET;
        if (inet_pton(AF_INET, address, &destination.sin_addr) != 1) return -1;
        destinationSize = sizeof(destination);
        memcpy(request.addresses, &destination, destinationSize);
        if (prefix >= 0) {
            struct sockaddr_in mask = {0};
            mask.sin_len = sizeof(mask); mask.sin_family = AF_INET;
            mask.sin_addr.s_addr = htonl(prefix ? UINT32_MAX << (32 - prefix) : 0);
            destination.sin_addr.s_addr &= mask.sin_addr.s_addr;
            memcpy(request.addresses, &destination, destinationSize);
            memcpy(request.addresses + destinationSize, &mask, sizeof(mask));
        }
    } else {
        struct sockaddr_in6 destination = {0};
        destination.sin6_len = sizeof(destination); destination.sin6_family = AF_INET6;
        if (inet_pton(AF_INET6, address, &destination.sin6_addr) != 1) return -1;
        destinationSize = sizeof(destination);
        memcpy(request.addresses, &destination, destinationSize);
    }
    request.header.rtm_msglen = sizeof(request.header) + destinationSize * (prefix >= 0 ? 2 : 1);
    request.header.rtm_version = RTM_VERSION;
    request.header.rtm_type = RTM_GET;
    request.header.rtm_addrs = RTA_DST | (prefix >= 0 ? RTA_NETMASK : 0);
    request.header.rtm_pid = getpid();
    request.header.rtm_seq = (int)(arc4random() & INT_MAX);
    int fd = socket(PF_ROUTE, SOCK_RAW, family);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    if (write(fd, &request, request.header.rtm_msglen) != request.header.rtm_msglen) { close(fd); return -1; }
    int result = -1;
    for (int attempt = 0; attempt < 8; ++attempt) {
        struct pollfd ready = {fd, POLLIN, 0};
        if (poll(&ready, 1, 100) <= 0) break;
        union { struct rt_msghdr header; unsigned char bytes[4096]; } response = {0};
        ssize_t length = read(fd, &response, sizeof(response));
        struct rt_msghdr *header = &response.header;
        if (length < sizeof(*header) || header->rtm_msglen < sizeof(*header) || header->rtm_msglen > length || header->rtm_version != RTM_VERSION || header->rtm_type != RTM_GET || header->rtm_pid != request.header.rtm_pid || header->rtm_seq != request.header.rtm_seq) continue;
        if (header->rtm_errno == ESRCH) result = 0;
        else if (header->rtm_errno == 0 && header->rtm_index && (header->rtm_flags & RTF_UP) && !(header->rtm_flags & (RTF_REJECT | RTF_BLACKHOLE))) {
            // Darwin may return its default route when an exact mask misses.
            // Never mistake that fallback for the requested underlying subnet.
            if (prefix >= 0 && ipv4RoutePrefix(response.bytes, header->rtm_msglen, header) != prefix) result = 0;
            else { *found = *header; result = 1; }
        }
        break;
    }
    close(fd);
    return result;
}

int keq_ipv6_route_uses_interface(const char *address, const char *interface_name) {
    unsigned int expected = if_nametoindex(interface_name);
    if (!expected) return 0;
    struct rt_msghdr found = {0};
    return routeLookup(AF_INET6, address, -1, &found) == 1 && found.rtm_index == expected;
}

int keq_ipv4_route_interface(const char *address, char *interface_name, size_t length) {
    if (!interface_name || length < IF_NAMESIZE) return 0;
    interface_name[0] = 0;
    struct rt_msghdr found = {0};
    int result = routeLookup(AF_INET, address, -1, &found);
    if (result < 0) return 0;
    // A proxy server or bootstrap resolver can legitimately have a /32 route
    // outside TUN. An exact key-mask lookup finds its underlying subnet route
    // without removing that exception or sending packets to the probe address.
    if (result == 0 || (found.rtm_flags & RTF_HOST)) {
        for (int prefix = 31; prefix >= 0; --prefix) {
            result = routeLookup(AF_INET, address, prefix, &found);
            if (result < 0) return 0;
            if (result == 1 && !(found.rtm_flags & RTF_HOST)) break;
        }
    }
    if (result != 1 || (found.rtm_flags & RTF_HOST)) return 0;
    return if_indextoname(found.rtm_index, interface_name) != NULL;
}
int keq_process_matches(pid_t pid, uint64_t start_time, const char *executable) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    return start_time != 0 && keq_process_start_time(pid) == start_time &&
        proc_pidpath(pid, path, sizeof(path)) > 0 && strcmp(path, executable) == 0;
}
pid_t keq_spawn_core(const char *executable, const char *const *arguments, const char *const *environment, const char *directory, uid_t uid, gid_t gid, int *output_fd, int *start_fd) {
    int pipes[2];
    if (pipe(pipes)) return -1;
    fcntl(pipes[0], F_SETFD, FD_CLOEXEC); fcntl(pipes[1], F_SETFD, FD_CLOEXEC);
    int gate[2];
    if (pipe(gate)) { close(pipes[0]); close(pipes[1]); return -1; }
    fcntl(gate[0], F_SETFD, FD_CLOEXEC); fcntl(gate[1], F_SETFD, FD_CLOEXEC);
    int input = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (input < 0) { close(pipes[0]); close(pipes[1]); close(gate[0]); close(gate[1]); return -1; }
    pid_t pid = fork();
    if (pid == 0) {
        // No Foundation/Swift/runtime calls between fork and exec.
        close(pipes[0]);
        close(gate[1]);
        unsigned char ready = 0;
        if (read(gate[0], &ready, 1) != 1 || ready != 1) _exit(125);
        close(gate[0]);
        if (setsid() < 0 || chdir(directory) || dup2(input, STDIN_FILENO) < 0 || dup2(pipes[1], STDOUT_FILENO) < 0 || dup2(pipes[1], STDERR_FILENO) < 0) _exit(126);
        close(input); close(pipes[1]); umask(077);
        if (setgroups(0, NULL) || setgid(gid) || setuid(uid)) _exit(126);
        execve(executable, (char *const *)arguments, (char *const *)environment);
        _exit(127);
    }
    int saved = errno;
    close(gate[0]);
    close(input); close(pipes[1]);
    if (pid < 0) { close(pipes[0]); close(gate[1]); errno = saved; return -1; }
    fcntl(pipes[0], F_SETFL, O_NONBLOCK);
    *output_fd = pipes[0];
    *start_fd = gate[1];
    return pid;
}

static int connectedSocket(const char *address, uint16_t port, int type, int timeout) {
    struct sockaddr_storage storage = {0}; socklen_t length;
    struct sockaddr_in *v4 = (struct sockaddr_in *)&storage;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&storage;
    int family;
    if (inet_pton(AF_INET, address, &v4->sin_addr) == 1) {
        family = AF_INET; v4->sin_family = AF_INET; v4->sin_len = sizeof(*v4); v4->sin_port = htons(port); length = sizeof(*v4);
    } else if (inet_pton(AF_INET6, address, &v6->sin6_addr) == 1) {
        family = AF_INET6; v6->sin6_family = AF_INET6; v6->sin6_len = sizeof(*v6); v6->sin6_port = htons(port); length = sizeof(*v6);
    } else return -1;
    int fd = socket(family, type, 0); if (fd < 0) return -1;
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    fcntl(fd, F_SETFD, FD_CLOEXEC); fcntl(fd, F_SETFL, O_NONBLOCK);
    if (connect(fd, (struct sockaddr *)&storage, length) && errno != EINPROGRESS) { close(fd); return -1; }
    struct pollfd pollfd = {fd, POLLOUT, 0};
    int error = 0; socklen_t errorLength = sizeof(error);
    if (poll(&pollfd, 1, timeout) <= 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorLength) || error) { close(fd); return -1; }
    fcntl(fd, F_SETFL, 0);
    struct timeval wait = {timeout / 1000, (timeout % 1000) * 1000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, sizeof(wait));
    return fd;
}
int keq_socket_ready(const char *address, uint16_t port, int timeout_ms) {
    int fd = connectedSocket(address, port, SOCK_STREAM, timeout_ms);
    if (fd < 0) return 0; close(fd); return 1;
}
int keq_port_available(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    int reuse = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_len = sizeof(address);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
    int result = bind(fd, (struct sockaddr *)&address, sizeof(address));
    close(fd);
    return result == 0;
}
static int removeContents(int fd, unsigned depth) {
    if (depth > 128) { errno = ELOOP; return -1; }
    DIR *directory = fdopendir(dup(fd));
    if (!directory) return -1;
    struct dirent *entry; int result = 0;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        struct stat info;
        if (fstatat(fd, entry->d_name, &info, AT_SYMLINK_NOFOLLOW)) { if (errno != ENOENT) result = -1; continue; }
        if (S_ISDIR(info.st_mode)) {
            int child = openat(fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0) { result = -1; continue; }
            if (removeContents(child, depth + 1)) result = -1;
            close(child);
            if (unlinkat(fd, entry->d_name, AT_REMOVEDIR) && errno != ENOENT) result = -1;
        } else if (unlinkat(fd, entry->d_name, 0) && errno != ENOENT) result = -1;
    }
    closedir(directory);
    return result;
}
int keq_remove_tree(const char *path) {
    // Callers only pass UUID paths beneath the root-owned sessions directory.
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    int result = removeContents(fd, 0); close(fd);
    if (rmdir(path) && errno != ENOENT) result = -1;
    return result;
}
int keq_interface_counters(const char *name, uint64_t *upload, uint64_t *download) {
    unsigned index = if_nametoindex(name);
    if (!index) return 0;
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, (int)index}; size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) || length == 0) return 0;
    char *buffer = malloc(length); if (!buffer) return 0;
    if (sysctl(mib, 6, buffer, &length, NULL, 0)) { free(buffer); return 0; }
    int found = 0;
    for (char *next = buffer; next + sizeof(struct if_msghdr) <= buffer + length;) {
        struct if_msghdr *header = (struct if_msghdr *)next;
        if (!header->ifm_msglen || next + header->ifm_msglen > buffer + length) break;
        if (header->ifm_type == RTM_IFINFO2 && header->ifm_msglen >= sizeof(struct if_msghdr2)) {
            struct if_msghdr2 *info = (struct if_msghdr2 *)next;
            if (info->ifm_index == index) { *upload = info->ifm_data.ifi_obytes; *download = info->ifm_data.ifi_ibytes; found = 1; break; }
        }
        next += header->ifm_msglen;
    }
    free(buffer); return found;
}
static int64_t dnsMonotonicNanoseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
    return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}
static int dnsRemainingMilliseconds(int64_t deadline) {
    int64_t now = dnsMonotonicNanoseconds();
    if (!now || now >= deadline) return 0;
    return (int)((deadline - now + 999999) / 1000000);
}
typedef struct {
    keq_dns_progress_callback callback;
    void *context;
} DNSProgress;
static int dnsWait(int fd, short events, int64_t deadline, DNSProgress progress) {
    for (;;) {
        int remaining = dnsRemainingMilliseconds(deadline);
        if (!remaining) return 0;
        if (progress.callback && !progress.callback(progress.context)) return 0;
        remaining = dnsRemainingMilliseconds(deadline);
        if (!remaining) return 0;
        struct pollfd descriptor = {fd, events, 0};
        int interval = progress.callback && remaining > 100 ? 100 : remaining;
        int result = poll(&descriptor, 1, interval);
        if (!result) continue;
        if (result < 0 && errno == EINTR) continue;
        return result > 0 && (descriptor.revents & events) && dnsRemainingMilliseconds(deadline) > 0;
    }
}
static int dnsConnectedSocket(const char *address, uint16_t port, int type, int64_t deadline, DNSProgress progress) {
    struct sockaddr_storage storage = {0}; socklen_t length;
    struct sockaddr_in *v4 = (struct sockaddr_in *)&storage;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&storage;
    int family;
    if (inet_pton(AF_INET, address, &v4->sin_addr) == 1) {
        family = AF_INET; v4->sin_family = AF_INET; v4->sin_len = sizeof(*v4); v4->sin_port = htons(port); length = sizeof(*v4);
    } else if (inet_pton(AF_INET6, address, &v6->sin6_addr) == 1) {
        family = AF_INET6; v6->sin6_family = AF_INET6; v6->sin6_len = sizeof(*v6); v6->sin6_port = htons(port); length = sizeof(*v6);
    } else return -1;
    int fd = socket(family, type, 0); if (fd < 0) return -1;
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) ||
        fcntl(fd, F_SETFD, FD_CLOEXEC) || fcntl(fd, F_SETFL, O_NONBLOCK)) { close(fd); return -1; }
    if (connect(fd, (struct sockaddr *)&storage, length) && errno != EINPROGRESS) { close(fd); return -1; }
    int error = 0; socklen_t errorLength = sizeof(error);
    if (!dnsWait(fd, POLLOUT, deadline, progress) || getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorLength) || error) { close(fd); return -1; }
    return fd;
}
static int dnsTransferExact(int fd, unsigned char *buffer, size_t length, int writing, int64_t deadline, DNSProgress progress) {
    size_t offset = 0;
    while (offset < length) {
        if (!dnsWait(fd, writing ? POLLOUT : POLLIN, deadline, progress)) return 0;
        ssize_t count = writing ? send(fd, buffer + offset, length - offset, 0) : recv(fd, buffer + offset, length - offset, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return 0;
        offset += (size_t)count;
    }
    return dnsRemainingMilliseconds(deadline) > 0;
}
int keq_dns_ready_with_progress(const char *address, uint16_t port, int tcp, int timeout_ms, keq_dns_progress_callback callback, void *context) {
    // Query localhost A. A real DNS reply (including NXDOMAIN) proves the listener
    // speaks DNS; merely binding a UDP socket does not prove readiness.
    unsigned char query[] = {0,0,1,0,0,1,0,0,0,0,0,0,9,'l','o','c','a','l','h','o','s','t',0,0,1,0,1};
    if (timeout_ms <= 0) return 0;
    int64_t now = dnsMonotonicNanoseconds();
    if (!now) return 0;
    // The same deadline covers connect, query, frame header and all body
    // fragments; a slow peer must not renew the budget with each byte.
    int64_t deadline = now + (int64_t)timeout_ms * 1000000;
    DNSProgress progress = {callback, context};
    uint16_t id = (uint16_t)arc4random(); query[0] = id >> 8; query[1] = id & 255;
    int fd = dnsConnectedSocket(address, port, tcp ? SOCK_STREAM : SOCK_DGRAM, deadline, progress);
    if (fd < 0) return 0;
    unsigned char response[4096]; ssize_t count = -1;
    if (tcp) {
        unsigned char framed[sizeof(query) + 2] = {0, sizeof(query)};
        memcpy(framed + 2, query, sizeof(query));
        if (dnsTransferExact(fd, framed, sizeof(framed), 1, deadline, progress)) {
            unsigned char size[2];
            if (dnsTransferExact(fd, size, 2, 0, deadline, progress)) {
                size_t expected = ((size_t)size[0] << 8) | size[1];
                if (expected >= 12 && expected <= sizeof(response)) {
                    if (dnsTransferExact(fd, response, expected, 0, deadline, progress)) count = (ssize_t)expected;
                }
            }
        }
    } else if (dnsWait(fd, POLLOUT, deadline, progress) && send(fd, query, sizeof(query), 0) == sizeof(query) && dnsWait(fd, POLLIN, deadline, progress)) {
        count = recv(fd, response, sizeof(response), 0);
    }
    close(fd);
    return dnsRemainingMilliseconds(deadline) > 0 && count >= 12 && response[0] == query[0] && response[1] == query[1] && (response[2] & 0x80);
}
int keq_dns_ready(const char *address, uint16_t port, int tcp, int timeout_ms) {
    return keq_dns_ready_with_progress(address, port, tcp, timeout_ms, NULL, NULL);
}
