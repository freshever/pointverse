package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type Task struct {
	ID      string            `json:"id"`
	User    string            `json:"-"`
	Session string            `json:"session_id"`
	Prompt  string            `json:"prompt"`
	Status  string            `json:"status"`
	Answer  string            `json:"answer,omitempty"`
	Error   string            `json:"error,omitempty"`
	Shots   map[string]string `json:"screenshots,omitempty"` // PNG base64, never public files
	Started time.Time         `json:"-"`
	Lease   string            `json:"lease,omitempty"`
}
type Server struct {
	mu     sync.Mutex
	tasks  map[string]*Task
	queue  []string
	active string
	users  map[string]string // token -> trusted user identity
	worker string
}

func id() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}
func equal(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }
func reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 12<<20)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		http.Error(w, "invalid JSON", 400)
		return false
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		http.Error(w, "extra JSON", 400)
		return false
	}
	return true
}
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	worker := strings.HasPrefix(r.URL.Path, "/worker/")
	user := ""
	if worker {
		if !equal(token, s.worker) {
			http.Error(w, "unauthorized", 401)
			return
		}
	} else {
		for t, u := range s.users {
			if equal(token, t) {
				user = u
				break
			}
		}
		if user == "" {
			http.Error(w, "unauthorized", 401)
			return
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// Never reassign an expired GUI lease: the old process could still be active.
	if s.active != "" {
		t := s.tasks[s.active]
		if t.Status == "running" && time.Since(t.Started) > 60*time.Second {
			t.Status = "failed"
			t.Error = "worker deadline exceeded; restart coordinator and worker to resume"
		}
	}
	switch {
	case r.Method == "POST" && r.URL.Path == "/tasks":
		var in struct {
			Session string `json:"session_id"`
			Prompt  string `json:"prompt"`
		}
		if !decode(w, r, &in) {
			return
		}
		if len(in.Prompt) == 0 || len(in.Prompt) > 16000 || len(in.Session) == 0 || len(in.Session) > 128 {
			http.Error(w, "invalid prompt or session", 400)
			return
		}
		if len(s.tasks) >= 1000 {
			http.Error(w, "POC task capacity reached", 503)
			return
		}
		t := &Task{ID: id(), User: user, Session: in.Session, Prompt: in.Prompt, Status: "queued"}
		s.tasks[t.ID] = t
		s.queue = append(s.queue, t.ID)
		reply(w, 202, t)
	case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/tasks/"):
		t := s.tasks[strings.TrimPrefix(r.URL.Path, "/tasks/")]
		if t == nil || t.User != user {
			http.NotFound(w, r)
			return
		}
		copy := *t
		copy.Lease = ""
		reply(w, 200, copy)
	case r.Method == "POST" && r.URL.Path == "/worker/claim":
		if s.active != "" || len(s.queue) == 0 {
			w.WriteHeader(204)
			return
		}
		t := s.tasks[s.queue[0]]
		s.queue = s.queue[1:]
		t.Status = "running"
		t.Started = time.Now()
		t.Lease = id()
		s.active = t.ID
		reply(w, 200, t)
	case r.Method == "POST" && r.URL.Path == "/worker/complete":
		var in struct {
			ID     string            `json:"id"`
			Lease  string            `json:"lease"`
			Answer string            `json:"answer"`
			Error  string            `json:"error"`
			Shots  map[string]string `json:"screenshots"`
		}
		if !decode(w, r, &in) {
			return
		}
		t := s.tasks[in.ID]
		if t == nil || s.active != in.ID || t.Status != "running" || !equal(t.Lease, in.Lease) {
			http.Error(w, "stale lease", 409)
			return
		}
		t.Answer = in.Answer
		t.Shots = in.Shots
		t.Error = in.Error
		t.Status = "completed"
		if in.Error != "" {
			t.Status = "failed"
		}
		t.Lease = ""
		s.active = ""
		reply(w, 200, map[string]string{"status": "ok"})
	default:
		http.NotFound(w, r)
	}
}
func main() {
	var users map[string]string
	if json.Unmarshal([]byte(os.Getenv("BRIDGE_USERS")), &users) != nil || len(users) == 0 {
		log.Fatal("BRIDGE_USERS must be a JSON token -> user map")
	}
	worker := os.Getenv("BRIDGE_WORKER_TOKEN")
	if len(worker) < 24 {
		log.Fatal("BRIDGE_WORKER_TOKEN needs at least 24 characters")
	}
	for token, user := range users {
		if len(token) < 24 || user == "" || equal(token, worker) {
			log.Fatal("invalid user credentials")
		}
	}
	s := &Server{tasks: map[string]*Task{}, users: users, worker: worker}
	srv := &http.Server{Addr: "127.0.0.1:8088", Handler: s, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 30 * time.Second}
	log.Print("bridge listening on http://127.0.0.1:8088")
	log.Fatal(srv.ListenAndServe())
}
