package dns

import (
	"context"
	"net"
	"time"

	"github.com/metacubex/mihomo/internal/keqdisdns"
	D "github.com/miekg/dns"
)

type bootstrapClient struct{ server string }

var dialBootstrap = keqdisdns.DialServer

func bootstrapClients() []dnsClient {
	servers := keqdisdns.Servers()
	clients := make([]dnsClient, 0, len(servers))
	for _, server := range servers {
		clients = append(clients, &bootstrapClient{server: server})
	}
	return clients
}

func (c *bootstrapClient) Address() string  { return "physical://" + net.JoinHostPort(c.server, "53") }
func (c *bootstrapClient) ResetConnection() {}

func (c *bootstrapClient) ExchangeContext(ctx context.Context, message *D.Msg) (*D.Msg, error) {
	answer, err := c.exchange(ctx, message, "udp")
	if err == nil && answer.Truncated {
		return c.exchange(ctx, message, "tcp")
	}
	return answer, err
}

func (c *bootstrapClient) exchange(ctx context.Context, message *D.Msg, network string) (*D.Msg, error) {
	conn, err := dialBootstrap(ctx, network, c.server)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	client := &D.Client{Net: network, Timeout: 5 * time.Second, UDPSize: 4096}
	answer, _, err := client.ExchangeWithConnContext(ctx, message, &D.Conn{Conn: conn, UDPSize: 4096})
	return answer, err
}
