// cdi-device-plugin: a small, generic kubelet device plugin that makes ONE
// CDI device requestable as ONE extended resource.
//
// Why this exists at all: CDI injection is the runtime's job, and a
// container gets a CDI device by naming it. Under podman that is a flag
// (--device vendor/class=device). Under kubernetes there is no such field
// on a pod - the only supported route into the CRI's CDI injection is a
// device plugin returning CDIDevices from Allocate(), which kubelet passes
// through in the CRI CDIDevices field. (Pod annotations do NOT work:
// kubelet builds a container's CRI annotations from device-plugin output
// only - see RunContainerOptions.Annotations, "not users".)
//
// So this plugin carries no knowledge of any particular device. It does
// not know what a display or a GPU is, and it never constructs mounts or
// environment variables. The CDI spec on the node is the single source of
// truth for what injection means; this process only routes a resource
// request to a CDI device name:
//
//	RESOURCE_NAME=desktop.local/display  CDI_DEVICE=desktop.local/display=all
//	  -> pods requesting desktop.local/display get whatever
//	     /etc/cdi/desktop-display.yaml says that device injects.
//
// One resource per process: kubelet's Register call takes a single
// resource name, so serving N devices means running N of these. That
// keeps this binary small and each deployment independently debuggable.
//
// Devices are advertised as COUNT interchangeable copies. The device
// plugin API allocates exclusively, so COUNT is simply the maximum number
// of concurrent claimants of a shareable device (a display, say); for a
// genuinely exclusive device leave it at 1.
//
// Health is CDI spec presence: the device is Healthy while it resolves in
// the spec dirs and Unhealthy once it stops resolving, so pods stay
// Pending rather than failing at container creation with an unresolvable
// device. That check is the same lookup the runtime will do, and it needs
// no device-specific knowledge.
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
	"tags.cncf.io/container-device-interface/pkg/cdi"
	"tags.cncf.io/container-device-interface/pkg/parser"
)

type config struct {
	cdiDevice      string
	resourceName   string
	count          int
	specDirs       []string
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
	dev := os.Getenv("CDI_DEVICE")
	if dev == "" {
		return config{}, fmt.Errorf("CDI_DEVICE is required, e.g. desktop.local/display=all")
	}
	// Fail here rather than advertise a resource that can never resolve.
	vendor, class, err := parseQualifiedName(dev)
	if err != nil {
		return config{}, fmt.Errorf("CDI_DEVICE %q is not a qualified CDI device name: %w", dev, err)
	}

	// Default the resource name to the device's kind, which is already a
	// vendor-qualified name and so is a legal extended resource. Override
	// it when that would collide with another plugin on the node (a real
	// nvidia.com/gpu plugin, say).
	res := envOr("RESOURCE_NAME", vendor+"/"+class)

	count, err := strconv.Atoi(envOr("COUNT", "1"))
	if err != nil || count < 1 {
		return config{}, fmt.Errorf("COUNT must be a positive integer: %q", os.Getenv("COUNT"))
	}
	interval, err := time.ParseDuration(envOr("HEALTH_INTERVAL", "5s"))
	if err != nil {
		return config{}, fmt.Errorf("HEALTH_INTERVAL invalid: %v", err)
	}

	var dirs []string
	for _, d := range strings.Split(envOr("CDI_SPEC_DIRS", "/etc/cdi,/var/run/cdi"), ",") {
		if d = strings.TrimSpace(d); d != "" {
			dirs = append(dirs, d)
		}
	}
	if len(dirs) == 0 {
		return config{}, fmt.Errorf("CDI_SPEC_DIRS is empty")
	}

	return config{
		cdiDevice:      dev,
		resourceName:   res,
		count:          count,
		specDirs:       dirs,
		pluginDir:      envOr("PLUGIN_DIR", "/var/lib/kubelet/device-plugins"),
		healthInterval: interval,
	}, nil
}

// parseQualifiedName validates a "vendor/class=device" name and returns
// its vendor and class.
//
// The recover() is not defensive programming for its own sake: as of
// container-device-interface v1.1.0, validateVendorOrClassName slices
// name[1:len(name)-1] without a length guard, so a single-character vendor
// or class ("a/b=c") panics instead of erroring. This function turns bad
// operator input into a clear startup error rather than a stack trace,
// which matters more here than usual - the name comes straight from
// config, so a typo is the likely cause.
func parseQualifiedName(device string) (vendor, class string, err error) {
	defer func() {
		if r := recover(); r != nil {
			vendor, class = "", ""
			err = fmt.Errorf("malformed name (CDI parser panicked on %q: %v)", device, r)
		}
	}()
	vendor, class, _, err = parser.ParseQualifiedName(device)
	return vendor, class, err
}

var nonAlnum = regexp.MustCompile(`[^a-zA-Z0-9]+`)

// socketName is derived from the resource name so that several instances
// of this plugin can share the kubelet plugin dir without colliding.
func (c config) socketName() string {
	return "cdi-" + strings.Trim(nonAlnum.ReplaceAllString(c.resourceName, "-"), "-") + ".sock"
}

type plugin struct {
	cfg   config
	cache *cdi.Cache

	mu      sync.Mutex
	healthy bool
	watches []chan struct{} // wake-up signals, one per ListAndWatch stream
}

// checkHealth reports whether the configured device currently resolves in
// the CDI spec dirs -- the same lookup the runtime performs at container
// creation, so a Healthy device is one the runtime can actually inject.
func (p *plugin) checkHealth() bool {
	// A refresh error is not fatal: one malformed spec from an unrelated
	// vendor must not hide our device, and the cache still reports what it
	// managed to parse. CDI itself rejects the injection if it disagrees.
	if err := p.cache.Refresh(); err != nil {
		log.Printf("CDI cache refresh reported errors (continuing): %v", err)
	}
	for _, name := range p.cache.ListDevices() {
		if name == p.cfg.cdiDevice {
			return true
		}
	}
	return false
}

// setHealth records the current health and wakes streams on change. The
// channels carry no data: streams read the current state themselves, so a
// dropped wake-up can never strand a stale value (the next one re-syncs).
func (p *plugin) setHealth(h bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if h == p.healthy {
		return
	}
	p.healthy = h
	log.Printf("%s is now %s", p.cfg.cdiDevice, map[bool]string{true: "resolvable (Healthy)", false: "unresolvable (Unhealthy)"}[h])
	for _, ch := range p.watches {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

func (p *plugin) currentHealth() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.healthy
}

func (p *plugin) devices(healthy bool) []*pluginapi.Device {
	health := pluginapi.Unhealthy
	if healthy {
		health = pluginapi.Healthy
	}
	devs := make([]*pluginapi.Device, p.cfg.count)
	for i := range devs {
		devs[i] = &pluginapi.Device{
			ID:     fmt.Sprintf("cdi-%d", i),
			Health: health,
		}
	}
	return devs
}

// --- pluginapi.DevicePluginServer -------------------------------------------

func (p *plugin) GetDevicePluginOptions(context.Context, *pluginapi.Empty) (*pluginapi.DevicePluginOptions, error) {
	return &pluginapi.DevicePluginOptions{}, nil
}

func (p *plugin) ListAndWatch(_ *pluginapi.Empty, stream pluginapi.DevicePlugin_ListAndWatchServer) error {
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

// Allocate names the CDI device and nothing else. Every mount, env var and
// device node comes from the CDI spec, applied by the runtime -- which is
// the whole point: podman and kubernetes clients resolve one definition.
//
// The allocated IDs are interchangeable copies of that one device, so the
// response is the same however many were handed out.
func (p *plugin) Allocate(_ context.Context, req *pluginapi.AllocateRequest) (*pluginapi.AllocateResponse, error) {
	resp := &pluginapi.AllocateResponse{}
	for range req.ContainerRequests {
		resp.ContainerResponses = append(resp.ContainerResponses, &pluginapi.ContainerAllocateResponse{
			CDIDevices: []*pluginapi.CDIDevice{{Name: p.cfg.cdiDevice}},
		})
	}
	return resp, nil
}

func (p *plugin) GetPreferredAllocation(context.Context, *pluginapi.PreferredAllocationRequest) (*pluginapi.PreferredAllocationResponse, error) {
	return &pluginapi.PreferredAllocationResponse{}, nil
}

func (p *plugin) PreStartContainer(context.Context, *pluginapi.PreStartContainerRequest) (*pluginapi.PreStartContainerResponse, error) {
	return &pluginapi.PreStartContainerResponse{}, nil
}

// --- lifecycle ---------------------------------------------------------------

// serveOnce runs one plugin lifetime: serve the gRPC socket, register with
// kubelet, watch health, and return when the socket vanishes (kubelet
// restart wipes the plugin dir -> caller re-registers) or ctx is done.
func serveOnce(ctx context.Context, cfg config) error {
	cache, err := cdi.NewCache(cdi.WithSpecDirs(cfg.specDirs...))
	if err != nil {
		return fmt.Errorf("cdi cache: %w", err)
	}
	p := &plugin{cfg: cfg, cache: cache, healthy: false}

	sockPath := filepath.Join(cfg.pluginDir, cfg.socketName())
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
	log.Printf("registered %q with kubelet (%d x %s, spec dirs %s)",
		cfg.resourceName, cfg.count, cfg.cdiDevice, strings.Join(cfg.specDirs, ","))

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
		Endpoint:     cfg.socketName(),
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
	log.Printf("cdi-device-plugin starting: resource=%s device=%s count=%d specDirs=%s pluginDir=%s",
		cfg.resourceName, cfg.cdiDevice, cfg.count, strings.Join(cfg.specDirs, ","), cfg.pluginDir)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := run(ctx, cfg); err != nil && ctx.Err() == nil {
		log.Fatalf("plugin exited: %v", err)
	}
	log.Printf("shutting down")
}
