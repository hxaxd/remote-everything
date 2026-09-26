package nodecore

import (
	"net/http"
	"time"
)

func (node *Node) Serve() error {
	cleanup, err := node.platform.PrepareLifetime()
	if err != nil {
		return err
	}
	defer cleanup()
	state, err := node.currentState()
	if err != nil {
		return err
	}
	go node.supervise()
	server := &http.Server{
		Addr:              state.ListenAddress,
		Handler:           http.HandlerFunc(node.gatewayHandler),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
	}
	return server.ListenAndServe()
}
