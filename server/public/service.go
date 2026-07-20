package main

import (
	"sync"
	"time"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

type publicService struct {
	paths            publicPaths
	config           publicState
	gateway          *gatewaycore.Gateway
	pairLock         sync.Mutex
	pairFailureDelay time.Duration
}

func newPublicService(paths publicPaths, config publicState) *publicService {
	return &publicService{paths: paths, config: config, pairFailureDelay: 350 * time.Millisecond}
}
