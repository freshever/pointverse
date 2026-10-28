package ai

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"pointverse/server/internal/auth"
)

const (
	maxRequestBytes = 1 << 20
	initialLatency  = time.Second
	latencyAlpha    = 0.2
)

type nodeState struct {
	url              *url.URL
	weight           float64
	mu               sync.Mutex
	inflight         int
	latencyEWMA      time.Duration
	failures         int
	unavailableUntil time.Time
}

type Handler struct {
	nodes          []*nodeState
	schedulerMu    sync.Mutex
	token          string
	model          string
	authentication *auth.Handler
	client         *http.Client
}

func New(rawURL, token, model string, authentication *auth.Handler) (*Handler, error) {
	if rawURL == "" {
		return nil, nil
	}
	nodes, err := parseNodes(rawURL)
	if err != nil {
		return nil, err
	}
	if authentication == nil {
		return nil, fmt.Errorf("AI requires authentication")
	}
	return &Handler{nodes: nodes, token: token, model: model, authentication: authentication, client: &http.Client{Timeout: 5 * time.Minute}}, nil
}

func parseNodes(raw string) ([]*nodeState, error) {
	var nodes []*nodeState
	for _, entry := range strings.Split(raw, ",") {
		parts := strings.Split(strings.TrimSpace(entry), "|")
		if len(parts) > 2 || parts[0] == "" {
			return nil, fmt.Errorf("AI_UPSTREAM_URL must contain http URLs with optional |weight")
		}
		u, err := url.Parse(parts[0])
		if err != nil || u.Scheme != "http" || u.Host == "" || u.User != nil {
			return nil, fmt.Errorf("AI_UPSTREAM_URL must contain http URLs with optional |weight")
		}
		weight := 1.0
		if len(parts) == 2 {
			weight, err = strconv.ParseFloat(parts[1], 64)
			if err != nil || weight <= 0 || math.IsInf(weight, 0) || math.IsNaN(weight) {
				return nil, fmt.Errorf("AI upstream weight must be a positive number")
			}
		}
		nodes = append(nodes, &nodeState{url: u, weight: weight, latencyEWMA: initialLatency})
	}
	return nodes, nil
}

func (h *Handler) Register(mux *http.ServeMux) {
	if h == nil {
		return
	}
	mux.HandleFunc("POST /v1/ai/chat/completions", h.authentication.RequireUser(h.chat))
	mux.HandleFunc("POST /v1/ai/audio/transcriptions", h.authentication.RequireUser(h.transcribe))
	for _, route := range []string{"/v1/ai/embeddings", "/v1/ai/audio/classifications", "/v1/ai/audio/speech", "/v1/ai/audio/analysis", "/v1/ai/images/generations"} {
		mux.HandleFunc("POST "+route, h.authentication.RequireUser(h.media))
	}
	mux.HandleFunc("GET /v1/ai/jobs/{jobID}", h.authentication.RequireUser(h.media))
	mux.HandleFunc("POST /v1/ai/jobs/{jobID}/cancel", h.authentication.RequireUser(h.media))
	mux.HandleFunc("GET /v1/ai/capabilities", h.authentication.RequireUser(h.media))
	// Browser requests use only the HttpOnly session and same-origin mutation guard.
	mux.HandleFunc("POST /web/ai/audio/transcriptions", h.authentication.RequireWebMutation(h.transcribe))
	mux.HandleFunc("POST /web/ai/images/generations", h.authentication.RequireWebMutation(h.webMedia))
	mux.HandleFunc("GET /web/ai/jobs/{jobID}", h.authentication.RequireWebUser(h.webMedia))
	mux.HandleFunc("POST /web/ai/jobs/{jobID}/cancel", h.authentication.RequireWebMutation(h.webMedia))
}

func (h *Handler) selectNode(excluded map[*nodeState]bool) *nodeState {
	h.schedulerMu.Lock()
	defer h.schedulerMu.Unlock()
	now := time.Now()
	var selected *nodeState
	bestScore := math.MaxFloat64
	for _, node := range h.nodes {
		if excluded[node] {
			continue
		}
		node.mu.Lock()
		available := !node.unavailableUntil.After(now)
		score := float64(node.latencyEWMA) * float64(node.inflight+1) / node.weight
		node.mu.Unlock()
		if available && score < bestScore {
			selected, bestScore = node, score
		}
	}
	if selected != nil {
		selected.mu.Lock()
		selected.inflight++
		selected.mu.Unlock()
	}
	return selected
}

func (h *Handler) recordResult(node *nodeState, latency time.Duration, failed bool) {
	node.mu.Lock()
	defer node.mu.Unlock()
	if node.inflight > 0 {
		node.inflight--
	}
	if failed {
		node.failures++
		if node.failures >= 2 {
			backoff := 5 * time.Second * time.Duration(1<<min(node.failures-2, 4))
			node.unavailableUntil = time.Now().Add(backoff)
		}
		return
	}
	node.failures = 0
	node.unavailableUntil = time.Time{}
	node.latencyEWMA = time.Duration(float64(node.latencyEWMA)*(1-latencyAlpha) + float64(latency)*latencyAlpha)
}

func retryableStatus(status int) bool {
	return status == http.StatusBadGateway || status == http.StatusServiceUnavailable || status == http.StatusGatewayTimeout
}

func (h *Handler) chat(w http.ResponseWriter, r *http.Request, user auth.User) {
	// Overwrite any caller-supplied identity with the authenticated account.
	r.Header.Set("X-PointVerse-Authenticated-User", user.ID)
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)
	var payload map[string]any
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	messages, ok := payload["messages"].([]any)
	if !ok || len(messages) == 0 {
		writeError(w, http.StatusBadRequest, "messages_required")
		return
	}
	switch payload["model"] {
	case "pointverse-cloud", "pointverse-cloud-enhanced":
		// Public model aliases are resolved by the private worker allowlist.
	default:
		payload["model"] = h.model
	}
	body, err := json.Marshal(payload)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}

	h.forward(w, r, body, "")
}

// The first speech contract accepts bounded base64 PCM16 mono 16kHz WAV.
// It deliberately accepts no user-provided URL or worker destination.
func (h *Handler) transcribe(w http.ResponseWriter, r *http.Request, _ auth.User) {
	r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
	var payload struct { Audio string `json:"audio"` }
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil || payload.Audio == "" {
		writeError(w, http.StatusBadRequest, "audio_required")
		return
	}
	body, _ := json.Marshal(payload)
	h.forward(w, r, body, "/v1/audio/transcriptions")
}

func (h *Handler) webMedia(w http.ResponseWriter, r *http.Request, user auth.User) {
	r.URL.Path = strings.Replace(r.URL.Path, "/web/ai/", "/v1/ai/", 1)
	w.Header().Set("Cache-Control", "no-store")
	h.media(w, r, user)
}

func (h *Handler) media(w http.ResponseWriter, r *http.Request, user auth.User) {
	r.Header.Set("X-PointVerse-Authenticated-User", user.ID)
	var destination string
	limit := int64(65536)
	switch r.URL.Path {
	case "/v1/ai/embeddings": destination = "/v1/embeddings"
	case "/v1/ai/audio/classifications": destination = "/v1/audio/classifications"; limit = 8 << 20
	case "/v1/ai/audio/analysis": destination = "/v1/audio/analysis"; limit = 8 << 20
	case "/v1/ai/audio/speech": destination = "/v1/audio/speech"
	case "/v1/ai/images/generations": destination = "/v1/images/generations"
	case "/v1/ai/capabilities": destination = "/v1/capabilities"
	default:
		id := r.PathValue("jobID")
		if len(id) != 36 || id[8] != '-' || id[13] != '-' || id[18] != '-' || id[23] != '-' || strings.ContainsAny(id, "/?%") {
			writeError(w, http.StatusBadRequest, "invalid_job_id"); return
		}
		for _, ch := range strings.ReplaceAll(id, "-", "") {
			if !strings.ContainsRune("0123456789abcdefABCDEF", ch) { writeError(w, http.StatusBadRequest, "invalid_job_id"); return }
		}
		destination = "/v1/jobs/" + id
		if r.Method == http.MethodPost { destination += "/cancel" }
	}
	var body []byte
	if r.Method == http.MethodPost {
		var err error
		body, err = io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
		if err != nil { writeError(w, http.StatusRequestEntityTooLarge, "request_too_large"); return }
	}
	h.forward(w, r, body, destination)
}

func (h *Handler) forward(w http.ResponseWriter, r *http.Request, body []byte, path string) {
	excluded := make(map[*nodeState]bool, len(h.nodes))
	var resp *http.Response
	var err error
	for range h.nodes {
		node := h.selectNode(excluded)
		if node == nil {
			break
		}
		excluded[node] = true
		destination := *node.url
		if path != "" { destination.Path = path; destination.RawPath = ""; destination.RawQuery = "" }
		req, requestErr := http.NewRequestWithContext(r.Context(), r.Method, destination.String(), bytes.NewReader(body))
		if requestErr != nil {
			h.recordResult(node, 0, true)
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-PointVerse-Authenticated-User", r.Header.Get("X-PointVerse-Authenticated-User"))
		if h.token != "" {
			req.Header.Set("Authorization", "Bearer "+h.token)
		}
		started := time.Now()
		resp, err = h.client.Do(req)
		latency := time.Since(started)
		failed := err != nil || (resp != nil && retryableStatus(resp.StatusCode))
		if err == nil && !retryableStatus(resp.StatusCode) {
			// Keep the reservation until the entire response finishes, not just headers.
			defer h.recordResult(node, latency, false)
			break
		}
		h.recordResult(node, latency, failed)
		if resp != nil {
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
			_ = resp.Body.Close()
			resp = nil
		}
	}
	if resp == nil {
		writeError(w, http.StatusBadGateway, "ai_unavailable")
		return
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	if strings.Contains(resp.Header.Get("Content-Type"), "text/event-stream") {
		w.Header().Set("Cache-Control", "no-cache")
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func writeError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": code, "message": code}})
}
