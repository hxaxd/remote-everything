package devicecore

import (
	"net"
	"net/http"
	"sync"
	"time"
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

func (limiter *rateLimiter) allow(clientIP string) bool {
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
	entry, ok := limiter.byIP[clientIP]
	if !ok {
		entry = &ipRateEntry{windowAt: now}
		limiter.byIP[clientIP] = entry
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

func clientIP(request *http.Request) string {
	if host, _, err := net.SplitHostPort(request.RemoteAddr); err == nil {
		return host
	}
	return request.RemoteAddr
}
