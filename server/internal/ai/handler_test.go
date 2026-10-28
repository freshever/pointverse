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
		if r.Header.Get("X-PointVerse-Authenticated-User") != "trusted-user" { t.Error("caller-controlled identity reached worker") }
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
	req.Header.Set("X-PointVerse-Authenticated-User", "spoofed-user")
	rec := httptest.NewRecorder()
	h.chat(rec, req, auth.User{ID: "trusted-user"})
	if rec.Code != 200 {
		t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestChatPreservesApprovedCloudChoices(t *testing.T) {
    for _, model := range []string{"pointverse-cloud", "pointverse-cloud-enhanced"} {
        t.Run(model, func(t *testing.T) {
            upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                var got map[string]any
                _ = json.NewDecoder(r.Body).Decode(&got)
                if got["model"] != model { t.Errorf("model = %v, want %s", got["model"], model) }
                _, _ = w.Write([]byte(`{"ok":true}`))
            }))
            defer upstream.Close()
            h := &Handler{nodes: []*nodeState{testNode(t, upstream.URL, 1, initialLatency, 0)}, model: "default", client: upstream.Client()}
            body := `{"model":"` + model + `","messages":[{"role":"user","content":"hi"}]}`
            rec := httptest.NewRecorder()
            h.chat(rec, httptest.NewRequest("POST", "/v1/ai/chat/completions", stringsReader(body)), auth.User{ID: "trusted-user"})
            if rec.Code != 200 { t.Fatalf("status = %d", rec.Code) }
        })
    }
}

func TestSpeechUsesSameWorkerWithFixedDestination(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/audio/transcriptions" { t.Errorf("path = %s", r.URL.Path) }
		var payload map[string]any
		_ = json.NewDecoder(r.Body).Decode(&payload)
		if len(payload) != 1 || payload["audio"] != "encoded" { t.Errorf("unexpected payload: %v", payload) }
		_, _ = w.Write([]byte(`{"text":"hello"}`))
	}))
	defer upstream.Close()
	h := &Handler{nodes: []*nodeState{testNode(t, upstream.URL+"/v1/chat/completions", 1, initialLatency, 0)}, client: upstream.Client()}
	req := httptest.NewRequest("POST", "/v1/ai/audio/transcriptions", stringsReader(`{"audio":"encoded","url":"http://untrusted"}`))
	rec := httptest.NewRecorder()
	h.transcribe(rec, req, auth.User{})
	if rec.Code != 200 { t.Fatalf("status = %d", rec.Code) }
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

func TestMediaRoutesPreserveMethodAndAuthenticatedOwner(t *testing.T) {
    for _, tc := range []struct { method, path, worker string }{
        {"POST", "/v1/ai/embeddings", "/v1/embeddings"},
        {"POST", "/v1/ai/audio/classifications", "/v1/audio/classifications"},
        {"POST", "/v1/ai/audio/speech", "/v1/audio/speech"},
        {"POST", "/v1/ai/images/generations", "/v1/images/generations"},
        {"GET", "/v1/ai/capabilities", "/v1/capabilities"},
        {"GET", "/v1/ai/jobs/12345678-1234-1234-1234-123456789abc", "/v1/jobs/12345678-1234-1234-1234-123456789abc"},
    } {
        t.Run(tc.path, func(t *testing.T) {
            upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                if r.Method != tc.method || r.URL.Path != tc.worker { t.Errorf("wrong destination: %s %s", r.Method, r.URL.Path) }
                if r.Header.Get("X-PointVerse-Authenticated-User") != "trusted-user" { t.Error("owner spoof reached worker") }
                if r.Header.Get("Authorization") != "Bearer internal-token" { t.Error("worker token not replaced") }
                _, _ = w.Write([]byte(`{"ok":true}`))
            }))
            defer upstream.Close()
            h := &Handler{nodes: []*nodeState{testNode(t, upstream.URL, 1, initialLatency, 0)}, token: "internal-token", client: upstream.Client()}
            req := httptest.NewRequest(tc.method, tc.path, stringsReader(`{}`))
            req.Header.Set("X-PointVerse-Authenticated-User", "spoofed-user")
            req.SetPathValue("jobID", "12345678-1234-1234-1234-123456789abc")
            rec := httptest.NewRecorder()
            h.media(rec, req, auth.User{ID: "trusted-user"})
            if rec.Code != 200 { t.Fatalf("status = %d", rec.Code) }
        })
    }
}

func TestWebImageRoutesUseFixedWorkerAndTrustedOwner(t *testing.T) {
	for _, method := range []string{"GET", "POST"} {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			want := "/v1/jobs/12345678-1234-1234-1234-123456789abc"
			if method == "POST" { want += "/cancel" }
			if r.URL.Path != want || r.Header.Get("X-PointVerse-Authenticated-User") != "owner" { t.Error("invalid browser forwarding") }
			w.Write([]byte(`{"status":"cancelled"}`))
		}))
		h := &Handler{nodes: []*nodeState{testNode(t, upstream.URL, 1, initialLatency, 0)}, client: upstream.Client()}
		path := "/web/ai/jobs/12345678-1234-1234-1234-123456789abc"
		if method == "POST" { path += "/cancel" }
		req := httptest.NewRequest(method, path, stringsReader(`{}`))
		req.SetPathValue("jobID", "12345678-1234-1234-1234-123456789abc")
		req.Header.Set("X-PointVerse-Authenticated-User", "attacker")
		w := httptest.NewRecorder()
		h.webMedia(w, req, auth.User{ID:"owner"})
		if w.Code != 200 || w.Header().Get("Cache-Control") != "no-store" { t.Fatal("invalid browser response") }
		upstream.Close()
	}
}

func TestWebMutationRejectsForeignOrMissingOriginBeforeAuthentication(t *testing.T) {
	h := &auth.Handler{}
	for _, origin := range []string{"", "https://evil.example", "null"} {
		req := httptest.NewRequest("POST", "https://dianjie.org/web/ai/images/generations", stringsReader(`{}`))
		req.Header.Set("Origin", origin)
		w := httptest.NewRecorder()
		h.RequireWebMutation(func(http.ResponseWriter, *http.Request, auth.User){t.Fatal("foreign origin reached AI")})(w, req)
		if w.Code != 403 { t.Fatalf("origin %q status %d", origin,w.Code) }
	}
}
