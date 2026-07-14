package main

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
)

// fakeKubelet implements the kubelet registration service.
type fakeKubelet struct {
	regCh chan *pluginapi.RegisterRequest
}

func (f *fakeKubelet) Register(_ context.Context, req *pluginapi.RegisterRequest) (*pluginapi.Empty, error) {
	f.regCh <- req
	return &pluginapi.Empty{}, nil
}

// TestPluginEndToEnd registers against a fake kubelet, then exercises
// ListAndWatch health transitions and Allocate over real gRPC sockets.
func TestPluginEndToEnd(t *testing.T) {
	pluginDir := t.TempDir()
	x11Dir := t.TempDir()
	audioDir := "/run/desktop-audio"

	// Fake kubelet registration server.
	fk := &fakeKubelet{regCh: make(chan *pluginapi.RegisterRequest, 1)}
	lis, err := net.Listen("unix", filepath.Join(pluginDir, filepath.Base(pluginapi.KubeletSocket)))
	if err != nil {
		t.Fatalf("fake kubelet listen: %v", err)
	}
	server := grpc.NewServer()
	pluginapi.RegisterRegistrationServer(server, fk)
	go server.Serve(lis)
	defer server.Stop()

	cfg := config{
		resourceName:   "desktop.local/display",
		slots:          10,
		display:        ":0",
		x11Dir:         x11Dir,
		audioDir:       audioDir,
		pluginDir:      pluginDir,
		healthInterval: 100 * time.Millisecond,
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runErr := make(chan error, 1)
	go func() { runErr <- run(ctx, cfg) }()

	// 1. Plugin registers with the right resource name and endpoint.
	select {
	case req := <-fk.regCh:
		if req.ResourceName != cfg.resourceName {
			t.Fatalf("registered resource %q, want %q", req.ResourceName, cfg.resourceName)
		}
		if req.Endpoint != socketName {
			t.Fatalf("registered endpoint %q, want %q", req.Endpoint, socketName)
		}
	case err := <-runErr:
		t.Fatalf("plugin exited before registering: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("plugin did not register within 10s")
	}

	// Dial the plugin's own socket, as kubelet would.
	conn, err := grpc.NewClient("unix://"+filepath.Join(pluginDir, socketName),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("dial plugin: %v", err)
	}
	defer conn.Close()
	client := pluginapi.NewDevicePluginClient(conn)

	// 2. ListAndWatch: 10 devices, Unhealthy while X0 absent.
	stream, err := client.ListAndWatch(ctx, &pluginapi.Empty{})
	if err != nil {
		t.Fatalf("ListAndWatch: %v", err)
	}
	first, err := stream.Recv()
	if err != nil {
		t.Fatalf("ListAndWatch recv: %v", err)
	}
	if len(first.Devices) != 10 {
		t.Fatalf("got %d devices, want 10", len(first.Devices))
	}
	if h := first.Devices[0].Health; h != pluginapi.Unhealthy {
		t.Fatalf("initial health %q, want Unhealthy (no X socket yet)", h)
	}

	// ...flips Healthy when the X socket appears.
	if err := os.WriteFile(filepath.Join(x11Dir, "X0"), nil, 0o666); err != nil {
		t.Fatalf("create fake X0: %v", err)
	}
	deadline := time.After(10 * time.Second)
	for {
		type recvResult struct {
			resp *pluginapi.ListAndWatchResponse
			err  error
		}
		rc := make(chan recvResult, 1)
		go func() {
			r, err := stream.Recv()
			rc <- recvResult{r, err}
		}()
		select {
		case r := <-rc:
			if r.err != nil {
				t.Fatalf("ListAndWatch recv: %v", r.err)
			}
			if r.resp.Devices[0].Health == pluginapi.Healthy {
				goto healthy
			}
		case <-deadline:
			t.Fatal("devices never became Healthy after X0 appeared")
		}
	}
healthy:

	// 3. Allocate: exactly the two socket mounts and three env vars.
	alloc, err := client.Allocate(ctx, &pluginapi.AllocateRequest{
		ContainerRequests: []*pluginapi.ContainerAllocateRequest{
			{DevicesIDs: []string{"display-0"}},
		},
	})
	if err != nil {
		t.Fatalf("Allocate: %v", err)
	}
	if len(alloc.ContainerResponses) != 1 {
		t.Fatalf("got %d container responses, want 1", len(alloc.ContainerResponses))
	}
	cr := alloc.ContainerResponses[0]

	wantEnvs := map[string]string{
		"DISPLAY":         ":0",
		"PULSE_SERVER":    "unix:/run/desktop-audio/pulse",
		"PIPEWIRE_REMOTE": "/run/desktop-audio/pipewire-0",
	}
	if len(cr.Envs) != len(wantEnvs) {
		t.Fatalf("got %d envs (%v), want %d", len(cr.Envs), cr.Envs, len(wantEnvs))
	}
	for k, want := range wantEnvs {
		if got := cr.Envs[k]; got != want {
			t.Errorf("env %s = %q, want %q", k, got, want)
		}
	}

	if len(cr.Mounts) != 2 {
		t.Fatalf("got %d mounts, want 2: %v", len(cr.Mounts), cr.Mounts)
	}
	wantMounts := map[string]bool{x11Dir: false, audioDir: false}
	for _, m := range cr.Mounts {
		seen, ok := wantMounts[m.HostPath]
		if !ok || seen {
			t.Errorf("unexpected/duplicate mount %v", m)
			continue
		}
		wantMounts[m.HostPath] = true
		if m.ContainerPath != m.HostPath {
			t.Errorf("mount %s: container path %s, want same as host", m.HostPath, m.ContainerPath)
		}
		if m.ReadOnly {
			t.Errorf("mount %s is read-only; unix connect(2) needs write access", m.HostPath)
		}
	}
	if len(cr.Devices) != 0 {
		t.Errorf("expected no DeviceSpecs, got %v", cr.Devices)
	}
}
