package main

import (
	"fmt"
	"io"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/res"
)

// listClients prints one line per connected X client:
//
//	client-base=0x02a00000 pid=214882
//
// The PID comes from the X-Resource 1.2 extension (XResQueryClientIds with
// the LocalClientPID mask), which reports the server's SO_PEERCRED view of
// each client connection. This desktop container runs in the HOST pid
// namespace (see deploy/.../desktop.container), so that view is a real host
// PID and /proc/<pid>/cgroup attributes the client to the k8s pod that owns
// it - the pod UID is in the cgroup path. That end-to-end chain is what the
// e2e verifies with this command.
//
// pid=0 means the server could not determine the peer PID. On this desktop
// that indicates the container is NOT sharing the host pid namespace (the
// regression this output exists to catch); on an ordinary desktop it is what
// a non-local or namespace-separated client looks like.
//
// This stays within the "both backends can honour it" contract from the
// package comment: a Wayland compositor knows its clients' PIDs natively
// (same SO_PEERCRED, its own socket), so `--list-clients` survives the
// backend swap with its meaning intact.
func listClients(c *xgb.Conn, w io.Writer) error {
	if err := res.Init(c); err != nil {
		return fmt.Errorf("X-Resource extension not available on this server: %w", err)
	}
	// Client=0 asks about every client; one spec, PID mask only. The reply
	// carries one ClientIdValue per client, its Spec.Client holding that
	// client's resource-ID base.
	spec := res.ClientIdSpec{Client: 0, Mask: res.ClientIdMaskLocalClientPID}
	reply, err := res.QueryClientIds(c, 1, []res.ClientIdSpec{spec}).Reply()
	if err != nil {
		return fmt.Errorf("XResQueryClientIds: %w", err)
	}
	for _, id := range reply.Ids {
		var pid uint32
		if len(id.Value) > 0 {
			pid = id.Value[0]
		}
		fmt.Fprintf(w, "client-base=0x%08x pid=%d\n", id.Spec.Client, pid)
	}
	return nil
}
