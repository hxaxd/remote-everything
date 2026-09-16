package nodeadapter

import (
	"net/http"
	"sync"
)

// State is a key-value store shared across hooks for one app instance.
// OnStart writes; OnRequest/OnResponse/OnStop read.
type State struct {
	m  map[string]string
	mu sync.RWMutex
}

func newState() *State {
	return &State{m: make(map[string]string)}
}

func (s *State) Get(key string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.m[key]
}

func (s *State) Set(key, val string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.m[key] = val
}

// jsReq wraps *http.Request for OnRequest, exposing only query/header mutation.
type jsReq struct {
	r *http.Request
}

func (j *jsReq) SetQuery(key, val string) {
	q := j.r.URL.Query()
	q.Set(key, val)
	j.r.URL.RawQuery = q.Encode()
}

func (j *jsReq) SetHeader(key, val string) {
	j.r.Header.Set(key, val)
}

func (j *jsReq) DelHeader(key string) {
	j.r.Header.Del(key)
}

// jsResp wraps *http.Response for OnResponse, exposing only header/status mutation.
type jsResp struct {
	r *http.Response
}

func (j *jsResp) SetHeader(key, val string) {
	j.r.Header.Set(key, val)
}

func (j *jsResp) DelHeader(key string) {
	j.r.Header.Del(key)
}

func (j *jsResp) SetStatus(code int) {
	j.r.StatusCode = code
}
