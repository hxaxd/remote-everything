package devicecore

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/hxaxd/remote-everything/internal/netaddr"
)

const (
	pairRateWindow       = time.Minute
	pairRateMaxPerIP     = 10
	pairRateGlobalMax    = 60
	pairMaxConcurrent    = 8
	pairRateCleanupEvery = 5 * time.Minute

	statusRateWindow       = time.Minute
	statusRateMaxPerIP     = 20
	statusRateGlobalMax    = 120
	statusMaxConcurrent    = 16
	statusRateCleanupEvery = 5 * time.Minute
)

type ipRateEntry struct {
	count    int
	windowAt time.Time
}

type rateLimiter struct {
	mu            sync.Mutex
	byIP          map[string]*ipRateEntry
	global        *ipRateEntry
	concurrent    int
	maxConcurrent int
	window        time.Duration
	maxPerIP      int
	globalMax     int
	cleanupEvery  time.Duration
	lastCleanup   time.Time
}

func newPairRateLimiter() *rateLimiter {
	return &rateLimiter{
		byIP:          make(map[string]*ipRateEntry),
		global:        &ipRateEntry{windowAt: time.Now()},
		window:        pairRateWindow,
		maxPerIP:      pairRateMaxPerIP,
		globalMax:     pairRateGlobalMax,
		maxConcurrent: pairMaxConcurrent,
		cleanupEvery:  pairRateCleanupEvery,
		lastCleanup:   time.Now(),
	}
}

func newStatusRateLimiter() *rateLimiter {
	return &rateLimiter{
		byIP:          make(map[string]*ipRateEntry),
		global:        &ipRateEntry{windowAt: time.Now()},
		window:        statusRateWindow,
		maxPerIP:      statusRateMaxPerIP,
		globalMax:     statusRateGlobalMax,
		maxConcurrent: statusMaxConcurrent,
		cleanupEvery:  statusRateCleanupEvery,
		lastCleanup:   time.Now(),
	}
}

func (limiter *rateLimiter) allow(address string) bool {
	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	now := time.Now()
	if now.Sub(limiter.lastCleanup) > limiter.cleanupEvery {
		for ip, entry := range limiter.byIP {
			if now.Sub(entry.windowAt) > limiter.window {
				delete(limiter.byIP, ip)
			}
		}
		limiter.lastCleanup = now
	}
	if limiter.global.windowAt.Add(limiter.window).Before(now) {
		limiter.global.count = 0
		limiter.global.windowAt = now
	}
	limiter.global.count++
	if limiter.global.count > limiter.globalMax {
		limiter.global.count--
		return false
	}
	entry, ok := limiter.byIP[address]
	if !ok {
		entry = &ipRateEntry{windowAt: now}
		limiter.byIP[address] = entry
	}
	if entry.windowAt.Add(limiter.window).Before(now) {
		entry.count = 0
		entry.windowAt = now
	}
	entry.count++
	if entry.count > limiter.maxPerIP {
		entry.count--
		return false
	}
	return true
}

func (limiter *rateLimiter) acquire() bool {
	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	if limiter.concurrent >= limiter.maxConcurrent {
		return false
	}
	limiter.concurrent++
	return true
}

func (limiter *rateLimiter) release() {
	limiter.mu.Lock()
	limiter.concurrent--
	if limiter.concurrent < 0 {
		limiter.concurrent = 0
	}
	limiter.mu.Unlock()
}

// ClientAddress is the address a request is counted against, which is the
// client rather than whichever machine relayed it. Endpoints that attribute
// requests — the pairing doors above all, where a credential can be guessed
// at — read it here, so every door counts the same client the same way.
//
// A request that arrives over loopback came from the entrance in front of this
// gateway — that entrance is the only thing that reaches a gateway listening on
// loopback, and it is what terminates TLS there — so the client is the one it
// names. The entrance overwrites what the client claimed for itself, which is what
// makes that name worth reading: counting every device as 127.0.0.1 would turn the
// per-client limits into one shared bucket for the whole deployment. A request from
// anywhere else is its own peer, and what it says about itself is not believed.
func ClientAddress(request *http.Request) string {
	host, _, err := net.SplitHostPort(request.RemoteAddr)
	if err != nil {
		return request.RemoteAddr
	}
	if !netaddr.ValidLoopbackHost(host) {
		return host
	}
	// The address the entrance added last is the one it saw the request come from;
	// anything before it in the list is what the client sent, or an earlier hop.
	forwarded := strings.Split(request.Header.Get("X-Forwarded-For"), ",")
	if last := strings.TrimSpace(forwarded[len(forwarded)-1]); last != "" {
		return last
	}
	return host
}
