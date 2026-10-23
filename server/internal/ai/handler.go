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

func (h *Handler) chat(w http.ResponseWriter, r *http.Request, _ auth.User) {
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
	payload["model"] = h.model
	body, err := json.Marshal(payload)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}

	excluded := make(map[*nodeState]bool, len(h.nodes))
	var resp *http.Response
	for range h.nodes {
		node := h.selectNode(excluded)
		if node == nil {
			break
		}
		excluded[node] = true
		req, requestErr := http.NewRequestWithContext(r.Context(), http.MethodPost, node.url.String(), bytes.NewReader(body))
		if requestErr != nil {
			h.recordResult(node, 0, true)
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		if h.token != "" {
			req.Header.Set("Authorization", "Bearer "+h.token)
		}
		started := time.Now()
		resp, err = h.client.Do(req)
		latency := time.Since(started)
		failed := err != nil || (resp != nil && retryableStatus(resp.StatusCode))
		h.recordResult(node, latency, failed)
		if err == nil && !retryableStatus(resp.StatusCode) {
			break
		}
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
