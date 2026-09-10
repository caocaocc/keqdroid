#ifndef KEQ_XPC_H
#define KEQ_XPC_H
#include <stdint.h>
#include <sys/types.h>

typedef void (*keq_reply_callback)(const char *json, void *context);
typedef void (*keq_request_callback)(const char *json, uid_t uid, gid_t gid, uint64_t client_id, void *reply, void *context);
void *keq_client_create(void);
void keq_client_destroy(void *client);
void keq_client_call(void *client, const char *json, keq_reply_callback callback, void *context);
int keq_authorization_external(unsigned char *bytes, size_t length, void **authorization);
void keq_authorization_release(void *authorization);
int keq_authorization_validate(const unsigned char *bytes, size_t length);
int keq_authorization_check_right(void);
int keq_server_start(const char *requirement, const char *app_path, keq_request_callback callback, void *context);
void keq_server_reply(void *reply, const char *json);
int keq_validate_code(const char *path, const char *requirement, int nested);
pid_t keq_spawn_core(const char *executable, const char *const *arguments, const char *const *environment, const char *directory, uid_t uid, gid_t gid, int *output_fd, int *start_fd);
uint64_t keq_process_start_time(pid_t pid);
int keq_process_matches(pid_t pid, uint64_t start_time, const char *executable);
int keq_socket_ready(const char *address, uint16_t port, int timeout_ms);
int keq_port_available(uint16_t port);
int keq_remove_tree(const char *path);
int keq_interface_counters(const char *name, uint64_t *upload, uint64_t *download);
int keq_dns_ready(const char *address, uint16_t port, int tcp, int timeout_ms);
// Read-only RTM_GET lookup. Returns 1 only when the IPv6 destination uses the
// exact interface; errors or absent routes return 0. Never changes routing.
int keq_ipv6_route_uses_interface(const char *address, const char *interface_name);
// Read-only IPv4 route lookup, excluding /32 host bypasses when identifying
// the underlying network route. Returns 0 on missing/rejected routes or errors.
int keq_ipv4_route_interface(const char *address, char *interface_name, size_t length);
#endif
