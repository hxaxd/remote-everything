package main

import (
	"bytes"
	"path/filepath"
	"testing"

	"github.com/hxaxd/remote-everything/internal/entrance"
	"github.com/hxaxd/remote-everything/internal/entrancetest"
)

func TestEmptyPublicGateway(t *testing.T) {
	t.Run("initialized without nodes", func(t *testing.T) {
		root := t.TempDir()
		if _, err := initializePublicState(root, "https://remote.example.com"); err != nil {
			t.Fatal(err)
		}
		harness := (&publicHarness{}).serve(t, root)
		entrancetest.CheckEmpty(t, harness)
		var output, failure bytes.Buffer
		open := func(root string) (entrance.Gateway, error) { return openPublicService(root) }
		if handled, code := entrance.Run([]string{"device", "--state", root, "list"}, open, &output, &failure); !handled || code != 0 {
			t.Fatalf("empty gateway device CLI: %s %s", output.String(), failure.String())
		}
	})
	t.Run("last node removed and added back", func(t *testing.T) {
		harness := startPublicEntrance(t)
		root := harness.root
		first := harness.service.State().Nodes[0]
		entrancetest.RunEmptyLifecycle(t, harness, func() {
			for _, node := range harness.service.State().Nodes {
				if _, err := removePublicNode(root, node.ID); err != nil {
					t.Fatal(err)
				}
			}
			harness.serve(t, root)
		}, func() {
			added, err := addPublicNode(root, first.Name, first.ID, first.Link, filepath.Join(t.TempDir(), "bootstrap"))
			if err != nil {
				t.Fatal(err)
			}
			harness.serveNode(t, first.ID, added.NodeAddress)
			harness.serve(t, root)
		})
	})
}
