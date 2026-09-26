package nodeadapter

import (
	"net/http"
	"sync"
	"time"

	"github.com/dop251/goja"
)

const readyTimeout = 5 * time.Second

// Adapter runs an optional JS adapter script for one app instance.
// All hook calls are serialized by mu (goja VM is not goroutine-safe).
type Adapter struct {
	source      string
	vm          *goja.Runtime
	mu          sync.Mutex
	state       *State
	ready       chan struct{}
	onStart     goja.Callable
	onRequest   goja.Callable
	onResponse  goja.Callable
	onStop      goja.Callable
	log         func(string, ...any)
	unavailable bool
}

// New parses source as JS and resolves the four hook functions.
// If source is empty or parsing fails, returns a non-nil Adapter with
// unavailable=true; all hook calls become no-ops.
func New(source string, log func(string, ...any)) *Adapter {
	a := &Adapter{
		source: source,
		state:  newState(),
		ready:  make(chan struct{}),
		log:    log,
	}
	if source == "" {
		a.unavailable = true
		return a
	}
	vm := goja.New()
	_, err := vm.RunString(source)
	if err != nil {
		a.unavailable = true
		a.log("adapter load failed: %v", err)
		return a
	}
	a.vm = vm
	a.onStart = a.lookup("onStart")
	a.onRequest = a.lookup("onRequest")
	a.onResponse = a.lookup("onResponse")
	a.onStop = a.lookup("onStop")
	return a
}

func (a *Adapter) lookup(name string) goja.Callable {
	val := a.vm.Get(name)
	if val == nil {
		return nil
	}
	fn, ok := goja.AssertFunction(val)
	if !ok {
		return nil
	}
	return fn
}

// Source returns the original JS source for change detection.
func (a *Adapter) Source() string {
	return a.source
}

// stateObject builds a goja object with get/set functions delegating to State.
func (a *Adapter) stateObject() *goja.Object {
	obj := a.vm.NewObject()
	obj.Set("get", func(key string) string { return a.state.Get(key) })
	obj.Set("set", func(key, val string) { a.state.Set(key, val) })
	return obj
}

// reqObject builds a goja object with setQuery/setHeader/delHeader and inspection methods.
func (a *Adapter) reqObject(req *http.Request) *goja.Object {
	w := &jsReq{r: req}
	obj := a.vm.NewObject()
	obj.Set("setQuery", w.SetQuery)
	obj.Set("setHeader", w.SetHeader)
	obj.Set("delHeader", w.DelHeader)
	obj.Set("getHeader", w.GetHeader)
	obj.Set("getQuery", w.GetQuery)
	obj.Set("getPath", w.GetPath)
	return obj
}

// respObject builds a goja object with setHeader/delHeader/setStatus and getHeader.
func (a *Adapter) respObject(resp *http.Response) *goja.Object {
	w := &jsResp{r: resp}
	obj := a.vm.NewObject()
	obj.Set("setHeader", w.SetHeader)
	obj.Set("delHeader", w.DelHeader)
	obj.Set("getHeader", w.GetHeader)
	obj.Set("setStatus", w.SetStatus)
	return obj
}

// OnStart is called after the app port opens, with the output the app wrote to
// its log while starting. Errors are logged but do not block the app.
func (a *Adapter) OnStart(stdout []byte, port int, appID string) {
	if a.unavailable || a.onStart == nil {
		close(a.ready)
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	defer func() {
		if r := recover(); r != nil {
			a.log("adapter onStart panic: %v", r)
		}
		close(a.ready)
	}()
	a.vm.Set("__state", a.stateObject())
	a.vm.Set("__stdout", string(stdout))
	a.vm.Set("__appId", appID)
	a.vm.Set("__port", port)
	if _, err := a.onStart(goja.Undefined()); err != nil {
		a.log("adapter onStart error: %v", err)
	}
}

// OnRequest is called before each request is forwarded to the app.
// Blocks until OnStart completes (or readyTimeout elapses).
//
// goja returns a thrown JS exception as an error from the callable, so the
// recover below only guards a Go-level panic from the bridge objects (a nil
// URL or header map reached from the script), not exceptions thrown by the
// adapter's own code.
func (a *Adapter) OnRequest(req *http.Request, appID string) {
	if a.unavailable || a.onRequest == nil {
		return
	}
	select {
	case <-a.ready:
	case <-time.After(readyTimeout):
		a.log("adapter onRequest timed out waiting for onStart (app %s)", appID)
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	defer func() {
		if r := recover(); r != nil {
			a.log("adapter onRequest panic: %v", r)
		}
	}()
	a.vm.Set("__state", a.stateObject())
	a.vm.Set("__appId", appID)
	a.vm.Set("__req", a.reqObject(req))
	if _, err := a.onRequest(goja.Undefined()); err != nil {
		a.log("adapter onRequest error: %v", err)
	}
}

// OnResponse is called after the app responds, before forwarding to client.
func (a *Adapter) OnResponse(resp *http.Response, appID string) {
	if a.unavailable || a.onResponse == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	defer func() {
		if r := recover(); r != nil {
			a.log("adapter onResponse panic: %v", r)
		}
	}()
	a.vm.Set("__state", a.stateObject())
	a.vm.Set("__appId", appID)
	a.vm.Set("__resp", a.respObject(resp))
	if _, err := a.onResponse(goja.Undefined()); err != nil {
		a.log("adapter onResponse error: %v", err)
	}
}

// OnStop is called when the app is stopping. Read-only state access.
func (a *Adapter) OnStop(appID string) {
	if a.unavailable || a.onStop == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	defer func() {
		if r := recover(); r != nil {
			a.log("adapter onStop panic: %v", r)
		}
	}()
	a.vm.Set("__state", a.stateObject())
	a.vm.Set("__appId", appID)
	if _, err := a.onStop(goja.Undefined()); err != nil {
		a.log("adapter onStop error: %v", err)
	}
}

// Unavailable reports whether the adapter failed to load.
func (a *Adapter) Unavailable() bool {
	return a.unavailable
}

// GetState returns the adapter's state (for testing).
func (a *Adapter) GetState() *State {
	return a.state
}
