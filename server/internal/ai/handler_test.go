package ai

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"pointverse/server/internal/auth"
)

func TestNewRejectsNonHTTPUpstream(t *testing.T) {
	if _, err := New("file:///tmp/socket", "", "qwen3:4b", &auth.Handler{}); err == nil {
		t.Fatal("accepted non-http AI upstream")
	}
}

func TestParseNodesReadsPerformanceWeights(t *testing.T) {
	nodes, err := parseNodes("http://100.64.0.1:11435/v1/chat/completions|2.5,http://100.64.0.2:11435/v1/chat/completions")
	if err != nil {
		t.Fatal(err)
	}
	if len(nodes) != 2 || nodes[0].weight != 2.5 || nodes[1].weight != 1 {
		t.Fatalf("unexpected nodes: %#v", nodes)
	}
}

func TestSelectNodeUsesLatencyLoadAndWeight(t *testing.T) {
	fast := testNode(t, "http://100.64.0.1", 2, 400*time.Millisecond, 1)
	slow := testNode(t, "http://100.64.0.2", 1, 900*time.Millisecond, 0)
	h := &Handler{nodes: []*nodeState{slow, fast}}
	if got := h.selectNode(nil); got != fast {
		t.Fatalf("selected %v, want faster weighted node", got.url)
	}
}

func TestCircuitBreakerSkipsFailingNode(t *testing.T) {
	bad := testNode(t, "http://100.64.0.1", 10, 10*time.Millisecond, 0)
	good := testNode(t, "http://100.64.0.2", 1, time.Second, 0)
	h := &Handler{nodes: []*nodeState{bad, good}}
	h.recordResult(bad, 0, true)
	h.recordResult(bad, 0, true)
	if got := h.selectNode(nil); got != good {
		t.Fatalf("selected circuit-open node %v", got.url)
	}
}

func TestChatPinsServerModel(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var got map[string]any
		_ = json.NewDecoder(r.Body).Decode(&got)
		if got["model"] != "qwen3:4b" {
			t.Errorf("model = %v", got["model"])
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer upstream.Close()
	h := &Handler{nodes: []*nodeState{testNode(t, upstream.URL, 1, initialLatency, 0)}, model: "qwen3:4b", client: upstream.Client()}
	req := httptest.NewRequest("POST", "/v1/ai/chat/completions", stringsReader(`{"model":"untrusted","messages":[{"role":"user","content":"hi"}]}`))
	rec := httptest.NewRecorder()
	h.chat(rec, req, auth.User{})
	if rec.Code != 200 {
		t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
	}
}

func testNode(t *testing.T, raw string, weight float64, latency time.Duration, inflight int) *nodeState {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return &nodeState{url: u, weight: weight, latencyEWMA: latency, inflight: inflight}
}

func stringsReader(s string) io.Reader { return strings.NewReader(s) }
