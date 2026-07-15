// desktop-device-plugin: a kubelet device plugin advertising a shareable
// "desktop" resource. Pods that request it get the desktop container's
// X display and audio: Allocate() injects the exported socket-directory
// mounts (/tmp/.X11-unix, /run/desktop-audio) and the DISPLAY /
// PULSE_SERVER / PIPEWIRE_REMOTE environment variables.
//
// Devices are virtual slots: the display is shareable, but the device
// plugin API allocates exclusively, so the advertised count is simply the
// maximum number of concurrent client pods. Slot health mirrors whether
// Xorg is actually serving (the X socket exists), so client pods stay
// unschedulable until the desktop is up.
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
)

const socketName = "desktop-display.sock"

type config struct {
	resourceName   string
	slots          int
	display        string
	x11Dir         string
	audioDir       string
	pluginDir      string
	healthInterval time.Duration
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func configFromEnv() (config, error) {
	slots, err := strconv.Atoi(envOr("SLOTS", "10"))
	if err != nil || slots < 1 {
		return config{}, fmt.Errorf("SLOTS must be a positive integer: %q", os.Getenv("SLOTS"))
	}
	interval, err := time.ParseDuration(envOr("HEALTH_INTERVAL", "5s"))
	if err != nil {
		return config{}, fmt.Errorf("HEALTH_INTERVAL invalid: %v", err)
	}
	return config{
		resourceName:   envOr("RESOURCE_NAME", "desktop.local/display"),
		slots:          slots,
		display:        envOr("DISPLAY_VALUE", ":0"),
		x11Dir:         envOr("X11_DIR", "/tmp/.X11-unix"),
		audioDir:       envOr("AUDIO_DIR", "/run/desktop-audio"),
		pluginDir:      envOr("PLUGIN_DIR", "/var/lib/kubelet/device-plugins"),
		healthInterval: interval,
	}, nil
}

type desktopPlugin struct {
	cfg config

	mu      sync.Mutex
	healthy bool
	watches []chan struct{} // wake-up signals, one per ListAndWatch stream
}

func (p *desktopPlugin) xSocketPath() string {
	// Xorg on DISPLAY=:N serves /tmp/.X11-unix/XN.
	num := "0"
	if len(p.cfg.display) > 1 && p.cfg.display[0] == ':' {
		num = p.cfg.display[1:]
	}
	return filepath.Join(p.cfg.x11Dir, "X"+num)
}

// checkHealth verifies Xorg is actually serving by connecting to the
// socket. A bare stat would report healthy on a stale socket file left
// behind by an ungracefully killed desktop (the host dir persists).
func (p *desktopPlugin) checkHealth() bool {
	conn, err := net.DialTimeout("unix", p.xSocketPath(), time.Second)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// setHealth records the current health and wakes streams on change. The
// channels carry no data: streams read the current state themselves, so a
// dropped wake-up can never strand a stale value (the next one re-syncs).
func (p *desktopPlugin) setHealth(h bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if h == p.healthy {
		return
	}
	p.healthy = h
	for _, ch := range p.watches {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

func (p *desktopPlugin) currentHealth() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.healthy
}

func (p *desktopPlugin) devices(healthy bool) []*pluginapi.Device {
	health := pluginapi.Unhealthy
	if healthy {
		health = pluginapi.Healthy
	}
	devs := make([]*pluginapi.Device, p.cfg.slots)
	for i := range devs {
		devs[i] = &pluginapi.Device{
			ID:     fmt.Sprintf("display-%d", i),
			Health: health,
		}
	}
	return devs
}

// --- pluginapi.DevicePluginServer -------------------------------------------

func (p *desktopPlugin) GetDevicePluginOptions(context.Context, *pluginapi.Empty) (*pluginapi.DevicePluginOptions, error) {
	return &pluginapi.DevicePluginOptions{}, nil
}

func (p *desktopPlugin) ListAndWatch(_ *pluginapi.Empty, stream pluginapi.DevicePlugin_ListAndWatchServer) error {
	ch := make(chan struct{}, 1)
	p.mu.Lock()
	p.watches = append(p.watches, ch)
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		for i, c := range p.watches {
			if c == ch {
				p.watches = append(p.watches[:i], p.watches[i+1:]...)
				break
			}
		}
		p.mu.Unlock()
	}()

	lastSent := p.currentHealth()
	if err := stream.Send(&pluginapi.ListAndWatchResponse{Devices: p.devices(lastSent)}); err != nil {
		return err
	}
	for {
		select {
		case <-ch:
			// Always transmit the CURRENT state, never a queued snapshot.
			h := p.currentHealth()
			if h == lastSent {
				continue
			}
			lastSent = h
			if err := stream.Send(&pluginapi.ListAndWatchResponse{Devices: p.devices(h)}); err != nil {
				return err
			}
		case <-stream.Context().Done():
			return nil
		}
	}
}

func (p *desktopPlugin) Allocate(_ context.Context, req *pluginapi.AllocateRequest) (*pluginapi.AllocateResponse, error) {
	resp := &pluginapi.AllocateResponse{}
	for range req.ContainerRequests {
		resp.ContainerResponses = append(resp.ContainerResponses, &pluginapi.ContainerAllocateResponse{
			Envs: map[string]string{
				"DISPLAY":         p.cfg.display,
				"PULSE_SERVER":    "unix:" + filepath.Join(p.cfg.audioDir, "pulse"),
				"PIPEWIRE_REMOTE": filepath.Join(p.cfg.audioDir, "pipewire-0"),
			},
			// rw: connect(2) on a unix socket needs write access to the
			// socket inode, which a read-only mount would deny.
			Mounts: []*pluginapi.Mount{
				{ContainerPath: p.cfg.x11Dir, HostPath: p.cfg.x11Dir, ReadOnly: false},
				{ContainerPath: p.cfg.audioDir, HostPath: p.cfg.audioDir, ReadOnly: false},
			},
		})
	}
	return resp, nil
}

func (p *desktopPlugin) GetPreferredAllocation(context.Context, *pluginapi.PreferredAllocationRequest) (*pluginapi.PreferredAllocationResponse, error) {
	return &pluginapi.PreferredAllocationResponse{}, nil
}

func (p *desktopPlugin) PreStartContainer(context.Context, *pluginapi.PreStartContainerRequest) (*pluginapi.PreStartContainerResponse, error) {
	return &pluginapi.PreStartContainerResponse{}, nil
}

// --- lifecycle ---------------------------------------------------------------

// serveOnce runs one plugin lifetime: serve the gRPC socket, register with
// kubelet, watch health, and return when the socket vanishes (kubelet
// restart wipes the plugin dir -> caller re-registers) or ctx is done.
func serveOnce(ctx context.Context, cfg config) error {
	p := &desktopPlugin{cfg: cfg, healthy: false}
	sockPath := filepath.Join(cfg.pluginDir, socketName)
	_ = os.Remove(sockPath)

	lis, err := net.Listen("unix", sockPath)
	if err != nil {
		return fmt.Errorf("listen %s: %w", sockPath, err)
	}
	server := grpc.NewServer()
	pluginapi.RegisterDevicePluginServer(server, p)
	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(lis) }()
	defer server.Stop()

	p.setHealth(p.checkHealth())

	if err := registerWithKubelet(ctx, cfg); err != nil {
		return err
	}
	log.Printf("registered %q with kubelet (%d slots, X socket %s)",
		cfg.resourceName, cfg.slots, p.xSocketPath())

	ticker := time.NewTicker(cfg.healthInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-serveErr:
			return fmt.Errorf("grpc server exited: %w", err)
		case <-ticker.C:
			p.setHealth(p.checkHealth())
			if _, err := os.Stat(sockPath); err != nil {
				log.Printf("plugin socket disappeared (kubelet restart?); re-registering")
				return nil
			}
		}
	}
}

func registerWithKubelet(ctx context.Context, cfg config) error {
	// pluginapi.KubeletSocket is an absolute default path; join only its
	// basename so a custom pluginDir (tests) works too.
	kubeletSock := filepath.Join(cfg.pluginDir, filepath.Base(pluginapi.KubeletSocket))

	conn, err := grpc.NewClient("unix://"+kubeletSock,
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("dial kubelet: %w", err)
	}
	defer conn.Close()

	client := pluginapi.NewRegistrationClient(conn)
	req := &pluginapi.RegisterRequest{
		Version:      pluginapi.Version,
		Endpoint:     socketName,
		ResourceName: cfg.resourceName,
	}
	// Retry: kubelet may not be up yet.
	for {
		callCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		_, err = client.Register(callCtx, req)
		cancel()
		if err == nil {
			return nil
		}
		log.Printf("kubelet registration failed (will retry): %v", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

func run(ctx context.Context, cfg config) error {
	for {
		if err := serveOnce(ctx, cfg); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

func main() {
	cfg, err := configFromEnv()
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	// First thing, before any I/O: an empty log stream from this pod means
	// the container is not running this binary at all.
	log.Printf("desktop-device-plugin starting: resource=%s slots=%d pluginDir=%s x11Dir=%s",
		cfg.resourceName, cfg.slots, cfg.pluginDir, cfg.x11Dir)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := run(ctx, cfg); err != nil && ctx.Err() == nil {
		log.Fatalf("plugin exited: %v", err)
	}
	log.Printf("shutting down")
}
