package main

import (
	"bytes"
	"path/filepath"
	"testing"

	"github.com/hxaxd/remote-everything/internal/gateway/entrance"
	"github.com/hxaxd/remote-everything/internal/gateway/entrancetest"
)

func TestEmptyLANGateway(t *testing.T) {
	t.Run("initialized without nodes", func(t *testing.T) {
		root := t.TempDir()
		if _, err := initializeLAN(root, "127.0.0.1", "", 30); err != nil {
			t.Fatal(err)
		}
		harness := (&lanHarness{}).serve(t, root)
		entrancetest.CheckEmpty(t, harness)
		var output, failure bytes.Buffer
		open := func(root string) (entrance.Gateway, error) { return openLANService(root) }
		if handled, code := entrance.Run([]string{"device", "--state", root, "list"}, open, &output, &failure); !handled || code != 0 {
			t.Fatalf("empty gateway device CLI: %s %s", output.String(), failure.String())
		}
	})
	t.Run("last node removed and added back", func(t *testing.T) {
		harness := startLANEntrance(t)
		root := harness.service.root
		first := harness.service.State().Nodes[0]
		entrancetest.RunEmptyLifecycle(t, harness, func() {
			for _, node := range harness.service.State().Nodes {
				if _, err := removeLANNode(root, node.ID); err != nil {
					t.Fatal(err)
				}
			}
			harness.serve(t, root)
		}, func() {
			if _, err := addLANNode(root, first.Name, first.ID, first.Address, first.Link, filepath.Join(t.TempDir(), "bootstrap")); err != nil {
				t.Fatal(err)
			}
			harness.serve(t, root)
		})
	})
}
