package musefinger

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"pointverse/server/internal/auth"
)

const maxScoreBytes int64 = 4 << 20
const maxAccountBytes int64 = 64 << 20
const maxScores = 200

var uuidPattern = regexp.MustCompile(`(?i)^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

type Handler struct {
	pool *pgxpool.Pool
	auth *auth.Handler
}

type scoreInput struct {
	Title    string `json:"title"`
	Composer string `json:"composer"`
	Source   string `json:"source"`
	MusicXML string `json:"musicxml"`
}

type score struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Composer  string    `json:"composer"`
	Source    string    `json:"source"`
	MusicXML  string    `json:"musicxml,omitempty"`
	ByteCount int64     `json:"byte_count"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

func New(pool *pgxpool.Pool, authentication *auth.Handler) *Handler {
	return &Handler{pool: pool, auth: authentication}
}

func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /web/musefinger/scores", h.auth.RequireWebUser(h.list))
	mux.HandleFunc("GET /web/musefinger/scores/{id}", h.auth.RequireWebUser(h.get))
	mux.HandleFunc("PUT /web/musefinger/scores/{id}", h.auth.RequireWebMutation(h.put))
	mux.HandleFunc("DELETE /web/musefinger/scores/{id}", h.auth.RequireWebMutation(h.remove))
}

func reply(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func fail(w http.ResponseWriter, status int, code string) {
	reply(w, status, map[string]any{"error": map[string]string{"code": code}})
}

func storageError(w http.ResponseWriter, err error) {
	slog.Error("MuseFinger score storage failed", "error_type", func() string {
		if errors.Is(err, context.DeadlineExceeded) {
			return "timeout"
		}
		return "database"
	}())
	fail(w, 500, "storage_error")
}

func validSource(value string) bool {
	switch value {
	case "import", "scan", "generated", "library":
		return true
	default:
		return false
	}
}

func validMusicXML(value string) bool {
	if value == "" || int64(len(value)) > maxScoreBytes {
		return false
	}
	decoder := xml.NewDecoder(strings.NewReader(value))
	for {
		token, err := decoder.Token()
		if err != nil {
			return false
		}
		if start, ok := token.(xml.StartElement); ok {
			return start.Name.Local == "score-partwise"
		}
	}
}

func readInput(w http.ResponseWriter, r *http.Request) (scoreInput, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxScoreBytes+8<<10)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var input scoreInput
	if decoder.Decode(&input) != nil {
		fail(w, 400, "invalid_score")
		return scoreInput{}, false
	}
	if decoder.Decode(new(any)) != io.EOF {
		fail(w, 400, "invalid_score")
		return scoreInput{}, false
	}
	input.Title, input.Composer = strings.TrimSpace(input.Title), strings.TrimSpace(input.Composer)
	if input.Title == "" || len(input.Title) > 300 || len(input.Composer) > 300 || !validSource(input.Source) || !validMusicXML(input.MusicXML) {
		fail(w, 400, "invalid_score")
		return scoreInput{}, false
	}
	return input, true
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request, user auth.User) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	rows, err := h.pool.Query(ctx, `SELECT id::text,title,composer,source,octet_length(musicxml),created_at,updated_at
		FROM musefinger_scores WHERE user_id=$1 ORDER BY updated_at DESC,id LIMIT $2`, user.ID, maxScores)
	if err != nil {
		storageError(w, err)
		return
	}
	defer rows.Close()
	items := []score{}
	for rows.Next() {
		var item score
		if err = rows.Scan(&item.ID, &item.Title, &item.Composer, &item.Source, &item.ByteCount, &item.CreatedAt, &item.UpdatedAt); err != nil {
			storageError(w, err)
			return
		}
		items = append(items, item)
	}
	if rows.Err() != nil {
		storageError(w, rows.Err())
		return
	}
	reply(w, 200, map[string]any{"items": items})
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request, user auth.User) {
	id := r.PathValue("id")
	if !uuidPattern.MatchString(id) {
		fail(w, 400, "invalid_score")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	var item score
	err := h.pool.QueryRow(ctx, `SELECT id::text,title,composer,source,musicxml,octet_length(musicxml),created_at,updated_at
		FROM musefinger_scores WHERE user_id=$1 AND id=$2`, user.ID, id).
		Scan(&item.ID, &item.Title, &item.Composer, &item.Source, &item.MusicXML, &item.ByteCount, &item.CreatedAt, &item.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		fail(w, 404, "not_found")
		return
	}
	if err != nil {
		storageError(w, err)
		return
	}
	reply(w, 200, item)
}

func (h *Handler) put(w http.ResponseWriter, r *http.Request, user auth.User) {
	id := r.PathValue("id")
	if !uuidPattern.MatchString(id) {
		fail(w, 400, "invalid_score")
		return
	}
	input, ok := readInput(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	tx, err := h.pool.Begin(ctx)
	if err != nil {
		storageError(w, err)
		return
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "musefinger:"+user.ID); err != nil {
		storageError(w, err)
		return
	}
	var count int
	var used int64
	var oldBytes int64
	err = tx.QueryRow(ctx, `SELECT count(*),COALESCE(sum(octet_length(musicxml)),0),
		COALESCE((SELECT octet_length(musicxml) FROM musefinger_scores WHERE user_id=$1 AND id=$2),0)
		FROM musefinger_scores WHERE user_id=$1`, user.ID, id).Scan(&count, &used, &oldBytes)
	if err != nil {
		storageError(w, err)
		return
	}
	if (oldBytes == 0 && count >= maxScores) || used-oldBytes+int64(len(input.MusicXML)) > maxAccountBytes {
		fail(w, 413, "score_quota_exceeded")
		return
	}
	var item score
	err = tx.QueryRow(ctx, `INSERT INTO musefinger_scores(user_id,id,title,composer,source,musicxml)
		VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(user_id,id) DO UPDATE SET
		title=EXCLUDED.title,composer=EXCLUDED.composer,source=EXCLUDED.source,musicxml=EXCLUDED.musicxml,updated_at=now()
		RETURNING id::text,title,composer,source,musicxml,octet_length(musicxml),created_at,updated_at`,
		user.ID, id, input.Title, input.Composer, input.Source, input.MusicXML).
		Scan(&item.ID, &item.Title, &item.Composer, &item.Source, &item.MusicXML, &item.ByteCount, &item.CreatedAt, &item.UpdatedAt)
	if err != nil {
		storageError(w, err)
		return
	}
	if err = tx.Commit(ctx); err != nil {
		storageError(w, err)
		return
	}
	reply(w, 200, item)
}

func (h *Handler) remove(w http.ResponseWriter, r *http.Request, user auth.User) {
	id := r.PathValue("id")
	if !uuidPattern.MatchString(id) {
		fail(w, 400, "invalid_score")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	result, err := h.pool.Exec(ctx, "DELETE FROM musefinger_scores WHERE user_id=$1 AND id=$2", user.ID, id)
	if err != nil {
		storageError(w, err)
		return
	}
	if result.RowsAffected() == 0 {
		fail(w, 404, "not_found")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(204)
}
