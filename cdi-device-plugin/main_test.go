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

const testSpec = `cdiVersion: 0.5.0
kind: test.local/widget
devices:
  - name: all
    containerEdits:
      env:
        - WIDGET=1
`

// TestPluginEndToEnd registers against a fake kubelet, then exercises
// ListAndWatch health transitions and Allocate over real gRPC sockets.
//
// The health transitions are driven by writing and removing a real CDI
// spec file, so what is under test is the same resolution the runtime
// performs -- not a stub of it.
func TestPluginEndToEnd(t *testing.T) {
	pluginDir := t.TempDir()
	specDir := t.TempDir()

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
		cdiDevice:      "test.local/widget=all",
		resourceName:   "test.local/widget",
		count:          3,
		specDirs:       []string{specDir},
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
		if req.Endpoint != cfg.socketName() {
			t.Fatalf("registered endpoint %q, want %q", req.Endpoint, cfg.socketName())
		}
	case err := <-runErr:
		t.Fatalf("plugin exited before registering: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("plugin did not register within 10s")
	}

	// Dial the plugin's own socket, as kubelet would.
	conn, err := grpc.NewClient("unix://"+filepath.Join(pluginDir, cfg.socketName()),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("dial plugin: %v", err)
	}
	defer conn.Close()
	client := pluginapi.NewDevicePluginClient(conn)

	// 2. ListAndWatch: COUNT devices, Unhealthy while no spec defines the
	// device -- a resource that cannot resolve must not look schedulable.
	stream, err := client.ListAndWatch(ctx, &pluginapi.Empty{})
	if err != nil {
		t.Fatalf("ListAndWatch: %v", err)
	}
	first, err := stream.Recv()
	if err != nil {
		t.Fatalf("ListAndWatch recv: %v", err)
	}
	if len(first.Devices) != cfg.count {
		t.Fatalf("got %d devices, want %d", len(first.Devices), cfg.count)
	}
	if h := first.Devices[0].Health; h != pluginapi.Unhealthy {
		t.Fatalf("initial health %q, want Unhealthy (no CDI spec yet)", h)
	}

	// Single background reader: all further stream messages flow through
	// one channel so no update can be consumed by an orphaned Recv.
	updates := make(chan *pluginapi.ListAndWatchResponse)
	go func() {
		for {
			r, err := stream.Recv()
			if err != nil {
				close(updates)
				return
			}
			updates <- r
		}
	}()

	// A spec that does NOT define our device must not flip us Healthy:
	// resolution is per-device, not per-file.
	other := filepath.Join(specDir, "other.yaml")
	if err := os.WriteFile(other, []byte("cdiVersion: 0.5.0\nkind: other.local/thing\ndevices:\n  - name: all\n    containerEdits:\n      env:\n        - OTHER=1\n"), 0o644); err != nil {
		t.Fatalf("write unrelated spec: %v", err)
	}
	select {
	case r := <-updates:
		t.Fatalf("an unrelated CDI spec triggered an update: %v", r.Devices[0].Health)
	case <-time.After(500 * time.Millisecond):
		// no update: correct
	}

	// ...but the real spec does.
	specFile := filepath.Join(specDir, "test.yaml")
	if err := os.WriteFile(specFile, []byte(testSpec), 0o644); err != nil {
		t.Fatalf("write spec: %v", err)
	}
	select {
	case r, ok := <-updates:
		if !ok {
			t.Fatal("ListAndWatch stream closed unexpectedly")
		}
		if h := r.Devices[0].Health; h != pluginapi.Healthy {
			t.Fatalf("update after the spec appeared has health %q, want Healthy", h)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("devices never became Healthy after the CDI spec appeared")
	}

	// 3. Allocate names the CDI device and nothing else. Mounts and env
	// belong to the spec; duplicating them here is the bug this plugin
	// exists to avoid, so their absence is the assertion.
	alloc, err := client.Allocate(ctx, &pluginapi.AllocateRequest{
		ContainerRequests: []*pluginapi.ContainerAllocateRequest{
			{DevicesIDs: []string{"cdi-0"}},
		},
	})
	if err != nil {
		t.Fatalf("Allocate: %v", err)
	}
	if len(alloc.ContainerResponses) != 1 {
		t.Fatalf("got %d container responses, want 1", len(alloc.ContainerResponses))
	}
	cr := alloc.ContainerResponses[0]
	if len(cr.CDIDevices) != 1 || cr.CDIDevices[0].Name != cfg.cdiDevice {
		t.Fatalf("CDIDevices = %v, want exactly [%s]", cr.CDIDevices, cfg.cdiDevice)
	}
	if len(cr.Mounts) != 0 {
		t.Errorf("Allocate returned mounts %v; injection is the CDI spec's job", cr.Mounts)
	}
	if len(cr.Envs) != 0 {
		t.Errorf("Allocate returned envs %v; injection is the CDI spec's job", cr.Envs)
	}
	if len(cr.Devices) != 0 {
		t.Errorf("Allocate returned device specs %v; injection is the CDI spec's job", cr.Devices)
	}

	// 4. Removing the spec takes the resource Unhealthy again, so pods
	// stop being scheduled onto a node that can no longer inject it.
	if err := os.Remove(specFile); err != nil {
		t.Fatalf("remove spec: %v", err)
	}
	select {
	case r, ok := <-updates:
		if !ok {
			t.Fatal("ListAndWatch stream closed unexpectedly")
		}
		if h := r.Devices[0].Health; h != pluginapi.Unhealthy {
			t.Fatalf("health after removing the spec is %q, want Unhealthy", h)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("devices never went Unhealthy after the CDI spec was removed")
	}
}

// TestConfigFromEnv covers the parsing rules that turn a CDI device name
// into a resource name and a unique socket, including the rejection of a
// device name the runtime could never resolve.
func TestConfigFromEnv(t *testing.T) {
	for _, tc := range []struct {
		name         string
		env          map[string]string
		wantErr      bool
		wantResource string
		wantSocket   string
		wantCount    int
	}{{
		name:         "resource name defaults to the CDI kind",
		env:          map[string]string{"CDI_DEVICE": "desktop.local/display=all"},
		wantResource: "desktop.local/display",
		wantSocket:   "cdi-desktop-local-display.sock",
		wantCount:    1,
	}, {
		name: "explicit resource name and count",
		env: map[string]string{
			"CDI_DEVICE":    "nvidia.com/gpu=all",
			"RESOURCE_NAME": "desktop.local/gpu",
			"COUNT":         "4",
		},
		wantResource: "desktop.local/gpu",
		wantSocket:   "cdi-desktop-local-gpu.sock",
		wantCount:    4,
	}, {
		name:    "missing device",
		env:     map[string]string{},
		wantErr: true,
	}, {
		name:    "unqualified device name",
		env:     map[string]string{"CDI_DEVICE": "not-a-cdi-device"},
		wantErr: true,
	}, {
		// container-device-interface v1.1.0 panics on a single-character
		// vendor or class; parseQualifiedName must turn that into an
		// ordinary error so a typo is a readable message, not a crash.
		name:    "single-character class (upstream parser panics)",
		env:     map[string]string{"CDI_DEVICE": "a/b=c"},
		wantErr: true,
	}, {
		name:    "zero count",
		env:     map[string]string{"CDI_DEVICE": "vendor.local/thing=all", "COUNT": "0"},
		wantErr: true,
	}, {
		name:    "non-numeric count",
		env:     map[string]string{"CDI_DEVICE": "vendor.local/thing=all", "COUNT": "many"},
		wantErr: true,
	}} {
		t.Run(tc.name, func(t *testing.T) {
			for _, k := range []string{"CDI_DEVICE", "RESOURCE_NAME", "COUNT", "HEALTH_INTERVAL", "CDI_SPEC_DIRS"} {
				t.Setenv(k, "")
				os.Unsetenv(k)
			}
			for k, v := range tc.env {
				t.Setenv(k, v)
			}
			cfg, err := configFromEnv()
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got config %+v", cfg)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if cfg.resourceName != tc.wantResource {
				t.Errorf("resourceName = %q, want %q", cfg.resourceName, tc.wantResource)
			}
			if got := cfg.socketName(); got != tc.wantSocket {
				t.Errorf("socketName = %q, want %q", got, tc.wantSocket)
			}
			if cfg.count != tc.wantCount {
				t.Errorf("count = %d, want %d", cfg.count, tc.wantCount)
			}
		})
	}
}
