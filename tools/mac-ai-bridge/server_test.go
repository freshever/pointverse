package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func call(s *Server, method, path, token, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func TestIsolationQueueAndLeases(t *testing.T) {
	s := &Server{tasks: map[string]*Task{}, users: map[string]string{"a": "alice", "b": "bob"}, worker: "worker"}
	submit := func(token string) Task {
		w := call(s, "POST", "/tasks", token, `{"session_id":"shared","prompt":"private"}`)
		if w.Code != 202 {
			t.Fatal(w.Code)
		}
		var j Task
		json.Unmarshal(w.Body.Bytes(), &j)
		return j
	}
	a := submit("a")
	b := submit("b")
	if call(s, "GET", "/tasks/"+a.ID, "b", "").Code != 404 {
		t.Fatal("cross-user access")
	}
	if call(s, "POST", "/worker/claim", "a", "{}").Code != 401 {
		t.Fatal("user claimed work")
	}
	w := call(s, "POST", "/worker/claim", "worker", "{}")
	var lease Task
	json.Unmarshal(w.Body.Bytes(), &lease)
	if w.Code != 200 || lease.ID != a.ID || lease.Lease == "" {
		t.Fatal("FIFO claim failed")
	}
	if call(s, "POST", "/worker/claim", "worker", "{}").Code != 204 {
		t.Fatal("parallel claim")
	}
	if strings.Contains(call(s, "GET", "/tasks/"+a.ID, "a", "").Body.String(), lease.Lease) {
		t.Fatal("lease leaked")
	}
	complete := func(key string) int {
		body, _ := json.Marshal(map[string]any{"id": a.ID, "lease": key, "answer": "secret", "screenshots": map[string]string{"final": "png"}})
		return call(s, "POST", "/worker/complete", "worker", string(body)).Code
	}
	if complete("stale") != 409 || complete(lease.Lease) != 200 || complete(lease.Lease) != 409 {
		t.Fatal("lease validation")
	}
	if call(s, "GET", "/tasks/"+a.ID, "b", "").Code != 404 {
		t.Fatal("result leaked")
	}
	w = call(s, "POST", "/worker/claim", "worker", "{}")
	var next Task
	json.Unmarshal(w.Body.Bytes(), &next)
	if next.ID != b.ID {
		t.Fatal("queue order")
	}
	s.tasks[b.ID].Started = time.Now().Add(-61 * time.Second)
	if call(s, "POST", "/worker/claim", "worker", "{}").Code != 204 || s.tasks[b.ID].Status != "failed" || s.active == "" {
		t.Fatal("expired worker must block scheduling")
	}
}
func TestValidation(t *testing.T) {
	s := &Server{tasks: map[string]*Task{}, users: map[string]string{"a": "alice"}, worker: "worker"}
	if call(s, "POST", "/tasks", "bad", "{}").Code != 401 {
		t.Fatal("authentication")
	}
	for _, b := range []string{`{}`, `{"prompt":"a","session_id":"s","user_id":"bob"}`, `{"prompt":"a","session_id":"s"} {}`} {
		if call(s, "POST", "/tasks", "a", b).Code != 400 {
			t.Fatal("invalid input accepted")
		}
	}
}
