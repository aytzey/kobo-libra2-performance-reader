#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef SO_BINDTODEVICE
#define SO_BINDTODEVICE 25
#endif

#define DHCP_SERVER_PORT 67
#define DHCP_CLIENT_PORT 68
#define DHCP_MAGIC 0x63825363U
#define DHCP_OP_BOOTREQUEST 1
#define DHCP_OP_BOOTREPLY 2
#define DHCP_HTYPE_ETHERNET 1
#define DHCP_OPTION_PAD 0
#define DHCP_OPTION_SUBNET 1
#define DHCP_OPTION_REQ_IP 50
#define DHCP_OPTION_LEASE 51
#define DHCP_OPTION_MSG_TYPE 53
#define DHCP_OPTION_SERVER_ID 54
#define DHCP_OPTION_RENEWAL 58
#define DHCP_OPTION_REBINDING 59
#define DHCP_OPTION_BROADCAST 28
#define DHCP_OPTION_END 255
#define DHCP_DISCOVER 1
#define DHCP_OFFER 2
#define DHCP_REQUEST 3
#define DHCP_ACK 5
#define DHCP_NAK 6
#define LEASE_SECONDS 3600U

struct dhcp_packet {
    uint8_t op;
    uint8_t htype;
    uint8_t hlen;
    uint8_t hops;
    uint32_t xid;
    uint16_t secs;
    uint16_t flags;
    uint32_t ciaddr;
    uint32_t yiaddr;
    uint32_t siaddr;
    uint32_t giaddr;
    uint8_t chaddr[16];
    uint8_t sname[64];
    uint8_t file[128];
    uint32_t magic;
    uint8_t options[312];
} __attribute__((packed));

static volatile sig_atomic_t running = 1;

static void stop_running(int signo) {
    (void)signo;
    running = 0;
}

static void put_option_u8(uint8_t **pos, uint8_t code, uint8_t value) {
    *(*pos)++ = code;
    *(*pos)++ = 1;
    *(*pos)++ = value;
}

static void put_option_u32(uint8_t **pos, uint8_t code, uint32_t value) {
    *(*pos)++ = code;
    *(*pos)++ = 4;
    memcpy(*pos, &value, 4);
    *pos += 4;
}

static int parse_message_type(const uint8_t *options, size_t len, uint32_t *requested_ip) {
    size_t i = 0;
    int type = 0;

    *requested_ip = 0;
    while (i < len) {
        uint8_t code = options[i++];
        uint8_t opt_len;

        if (code == DHCP_OPTION_PAD) {
            continue;
        }
        if (code == DHCP_OPTION_END) {
            break;
        }
        if (i >= len) {
            break;
        }
        opt_len = options[i++];
        if (i + opt_len > len) {
            break;
        }

        if (code == DHCP_OPTION_MSG_TYPE && opt_len == 1) {
            type = options[i];
        } else if (code == DHCP_OPTION_REQ_IP && opt_len == 4) {
            memcpy(requested_ip, options + i, 4);
        }
        i += opt_len;
    }

    return type;
}

static uint32_t broadcast_from(uint32_t host_ip, uint32_t netmask) {
    uint32_t ip = ntohl(host_ip);
    uint32_t mask = ntohl(netmask);
    return htonl((ip & mask) | ~mask);
}

static size_t build_reply(struct dhcp_packet *reply,
                          const struct dhcp_packet *request,
                          int reply_type,
                          uint32_t device_ip,
                          uint32_t host_ip,
                          uint32_t netmask) {
    uint8_t *pos;
    uint32_t lease = htonl(LEASE_SECONDS);
    uint32_t renewal = htonl(LEASE_SECONDS / 2U);
    uint32_t rebinding = htonl((LEASE_SECONDS * 7U) / 8U);
    uint32_t broadcast = broadcast_from(host_ip, netmask);

    memset(reply, 0, sizeof(*reply));
    reply->op = DHCP_OP_BOOTREPLY;
    reply->htype = request->htype ? request->htype : DHCP_HTYPE_ETHERNET;
    reply->hlen = request->hlen ? request->hlen : 6;
    reply->xid = request->xid;
    reply->flags = request->flags;
    reply->yiaddr = host_ip;
    reply->siaddr = device_ip;
    memcpy(reply->chaddr, request->chaddr, sizeof(reply->chaddr));
    reply->magic = htonl(DHCP_MAGIC);

    pos = reply->options;
    put_option_u8(&pos, DHCP_OPTION_MSG_TYPE, (uint8_t)reply_type);
    put_option_u32(&pos, DHCP_OPTION_SERVER_ID, device_ip);
    put_option_u32(&pos, DHCP_OPTION_LEASE, lease);
    put_option_u32(&pos, DHCP_OPTION_RENEWAL, renewal);
    put_option_u32(&pos, DHCP_OPTION_REBINDING, rebinding);
    put_option_u32(&pos, DHCP_OPTION_SUBNET, netmask);
    put_option_u32(&pos, DHCP_OPTION_BROADCAST, broadcast);
    *pos++ = DHCP_OPTION_END;

    return (size_t)((uint8_t *)pos - (uint8_t *)reply);
}

static size_t build_nak(struct dhcp_packet *reply,
                        const struct dhcp_packet *request,
                        uint32_t device_ip) {
    uint8_t *pos;

    memset(reply, 0, sizeof(*reply));
    reply->op = DHCP_OP_BOOTREPLY;
    reply->htype = request->htype ? request->htype : DHCP_HTYPE_ETHERNET;
    reply->hlen = request->hlen ? request->hlen : 6;
    reply->xid = request->xid;
    reply->flags = request->flags;
    reply->siaddr = device_ip;
    memcpy(reply->chaddr, request->chaddr, sizeof(reply->chaddr));
    reply->magic = htonl(DHCP_MAGIC);

    pos = reply->options;
    put_option_u8(&pos, DHCP_OPTION_MSG_TYPE, DHCP_NAK);
    put_option_u32(&pos, DHCP_OPTION_SERVER_ID, device_ip);
    *pos++ = DHCP_OPTION_END;

    return (size_t)((uint8_t *)pos - (uint8_t *)reply);
}

static int open_socket(const char *iface) {
    int fd;
    int on = 1;
    struct sockaddr_in addr;

    fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        perror("socket");
        return -1;
    }

    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));
    if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, iface, strlen(iface) + 1) != 0) {
        fprintf(stderr, "warning: SO_BINDTODEVICE(%s) failed: %s\n", iface, strerror(errno));
    }

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(DHCP_SERVER_PORT);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        close(fd);
        return -1;
    }

    return fd;
}

int main(int argc, char **argv) {
    const char *iface;
    uint32_t device_ip;
    uint32_t host_ip;
    uint32_t netmask;
    int fd;
    struct sockaddr_in dest;

    if (argc != 5) {
        fprintf(stderr, "usage: %s <iface> <device-ip> <host-ip> <netmask>\n", argv[0]);
        return 2;
    }

    iface = argv[1];
    if (inet_pton(AF_INET, argv[2], &device_ip) != 1 ||
        inet_pton(AF_INET, argv[3], &host_ip) != 1 ||
        inet_pton(AF_INET, argv[4], &netmask) != 1) {
        fprintf(stderr, "invalid IPv4 argument\n");
        return 2;
    }

    signal(SIGTERM, stop_running);
    signal(SIGINT, stop_running);
    signal(SIGHUP, SIG_IGN);
    setvbuf(stdout, NULL, _IOLBF, 0);

    fd = open_socket(iface);
    if (fd < 0) {
        return 1;
    }

    memset(&dest, 0, sizeof(dest));
    dest.sin_family = AF_INET;
    dest.sin_port = htons(DHCP_CLIENT_PORT);
    dest.sin_addr.s_addr = htonl(INADDR_BROADCAST);

    printf("serving %s to DHCP clients on %s from %s\n", argv[3], iface, argv[2]);
    while (running) {
        uint8_t buf[1500];
        struct dhcp_packet reply;
        ssize_t n;
        uint32_t requested_ip;
        int msg_type;
        int reply_type;
        size_t reply_len;

        n = recv(fd, buf, sizeof(buf), 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("recv");
            break;
        }
        if ((size_t)n < offsetof(struct dhcp_packet, options) ||
            ((const struct dhcp_packet *)buf)->op != DHCP_OP_BOOTREQUEST ||
            ntohl(((const struct dhcp_packet *)buf)->magic) != DHCP_MAGIC) {
            continue;
        }

        msg_type = parse_message_type(((const struct dhcp_packet *)buf)->options,
                                      (size_t)n - offsetof(struct dhcp_packet, options),
                                      &requested_ip);
        if (msg_type == DHCP_DISCOVER) {
            reply_type = DHCP_OFFER;
        } else if (msg_type == DHCP_REQUEST) {
            reply_type = DHCP_ACK;
        } else {
            continue;
        }

        if (requested_ip != 0 && requested_ip != host_ip) {
            reply_len = build_nak(&reply, (const struct dhcp_packet *)buf, device_ip);
            if (sendto(fd, &reply, reply_len, 0, (struct sockaddr *)&dest, sizeof(dest)) < 0) {
                perror("sendto");
            } else {
                printf("nak sent for stale lease\n");
            }
            continue;
        }

        reply_len = build_reply(&reply, (const struct dhcp_packet *)buf, reply_type,
                                device_ip, host_ip, netmask);
        if (sendto(fd, &reply, reply_len, 0, (struct sockaddr *)&dest, sizeof(dest)) < 0) {
            perror("sendto");
        } else {
            printf("%s sent\n", reply_type == DHCP_OFFER ? "offer" : "ack");
        }
    }

    close(fd);
    return 0;
}
