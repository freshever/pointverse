package cloud

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"pointverse/server/internal/auth"
)

const maxAsset int64 = 128 << 20

var hashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var uuidPattern = regexp.MustCompile(`(?i)^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

type Handler struct {
	pool           *pgxpool.Pool
	root           string
	authentication *auth.Handler
}

func New(pool *pgxpool.Pool, root string, authentication *auth.Handler) (*Handler, error) {
	absolute, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(absolute, 0700); err != nil {
		return nil, err
	}
	return &Handler{pool, absolute, authentication}, nil
}
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("PUT /web/sync/assets/{hash}", h.authentication.RequireWebMutation(h.uploadAsset))
	mux.HandleFunc("POST /web/sync/points", h.authentication.RequireWebMutation(h.commit))
	mux.HandleFunc("GET /web/sync/points", h.authentication.RequireWebUser(h.list))
	mux.HandleFunc("GET /web/sync/assets/{hash}", h.authentication.RequireWebUser(h.downloadAsset))
	mux.HandleFunc("GET /web/sync/points/{point}/versions/{hash}", h.authentication.RequireWebUser(h.downloadManifest))
	mux.HandleFunc("PUT /v1/sync/assets/{hash}", h.authentication.RequireUser(h.uploadAsset))
	mux.HandleFunc("GET /v1/sync/assets/{hash}", h.authentication.RequireUser(h.downloadAsset))
	mux.HandleFunc("POST /v1/sync/points", h.authentication.RequireUser(h.commit))
	mux.HandleFunc("GET /v1/sync/points", h.authentication.RequireUser(h.list))
	mux.HandleFunc("GET /v1/sync/points/{point}/versions/{hash}", h.authentication.RequireUser(h.downloadManifest))
}
func write(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func fail(w http.ResponseWriter, status int, code string) {
	write(w, status, map[string]any{"error": map[string]string{"code": code}})
}
func (h *Handler) uploadAsset(w http.ResponseWriter, r *http.Request, user auth.User) {
	hash := r.PathValue("hash")
	if !hashPattern.MatchString(hash) {
		fail(w, 400, "invalid_asset")
		return
	}
	if r.ContentLength <= 0 || r.ContentLength > maxAsset {
		fail(w, 413, "asset_too_large")
		return
	}
	directory := filepath.Join(h.root, user.ID)
	if err := os.MkdirAll(directory, 0700); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	temp, err := os.CreateTemp(directory, "upload-*")
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	defer os.Remove(temp.Name())
	defer temp.Close()
	hasher := sha256.New()
	r.Body = http.MaxBytesReader(w, r.Body, maxAsset)
	size, err := io.Copy(io.MultiWriter(temp, hasher), r.Body)
	if err != nil || size != r.ContentLength || hex.EncodeToString(hasher.Sum(nil)) != hash {
		fail(w, 400, "asset_checksum_mismatch")
		return
	}
	if err = temp.Sync(); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	if err = temp.Close(); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	tx, err := h.pool.Begin(ctx)
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "cloud:"+user.ID); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	var used int64
	var existing bool
	err = tx.QueryRow(ctx, "SELECT COALESCE(sum(byte_count),0),COALESCE(bool_or(sha256=$2),false) FROM cloud_assets WHERE user_id=$1", user.ID, hash).Scan(&used, &existing)
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	if !existing && used+size > 2<<30 {
		fail(w, 413, "storage_quota_exceeded")
		return
	}
	if err = os.Rename(temp.Name(), filepath.Join(directory, hash)); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	_, err = tx.Exec(ctx, "INSERT INTO cloud_assets(user_id,sha256,byte_count) VALUES($1,$2,$3) ON CONFLICT DO NOTHING", user.ID, hash, size)
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 201, map[string]any{"sha256": hash, "byte_count": size})
}
func (h *Handler) downloadAsset(w http.ResponseWriter, r *http.Request, user auth.User) {
	hash := r.PathValue("hash")
	if !hashPattern.MatchString(hash) {
		fail(w, 400, "invalid_asset")
		return
	}
	var size int64
	err := h.pool.QueryRow(r.Context(), "SELECT byte_count FROM cloud_assets WHERE user_id=$1 AND sha256=$2", user.ID, hash).Scan(&size)
	if errors.Is(err, pgx.ErrNoRows) {
		fail(w, 404, "not_found")
		return
	}
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	file, err := os.Open(filepath.Join(h.root, user.ID, hash))
	if err != nil {
		fail(w, 404, "not_found")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() != size {
		fail(w, 500, "storage_error")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	prefix := make([]byte, 512)
	n, _ := file.Read(prefix)
	_, _ = file.Seek(0, io.SeekStart)
	media := http.DetectContentType(prefix[:n])
	inline := media == "image/jpeg" || media == "image/png" || media == "image/gif" || media == "image/webp" || media == "audio/wave" || media == "audio/x-wav" || media == "audio/mpeg" || media == "audio/ogg"
	if n >= 12 && string(prefix[4:8]) == "ftyp" {
		media = "audio/mp4"
		inline = true
	}
	if !inline {
		media = "application/octet-stream"
	}
	w.Header().Set("Content-Type", media)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	disposition := "attachment"
	if inline {
		disposition = "inline"
	}
	w.Header().Set("Content-Disposition", disposition+`; filename="`+hash+`"`)
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	if r.Method == http.MethodHead {
		return
	}
	http.ServeContent(w, r, hash, info.ModTime(), file)
}

type Asset struct {
	ID        string `json:"id"`
	SHA256    string `json:"sha256"`
	ByteCount int64  `json:"byte_count"`
	Kind      string `json:"kind"`
}
type Manifest struct {
	FormatVersion int             `json:"format_version"`
	PointID       string          `json:"point_id"`
	Revision      int64           `json:"revision"`
	Title         string          `json:"title"`
	Preview       string          `json:"preview"`
	CreatedAt     float64         `json:"created_at"`
	Assets        []Asset         `json:"assets"`
	Payload       json.RawMessage `json:"payload"`
}
type Version struct {
	PointID       string    `json:"point_id"`
	ManifestHash  string    `json:"manifest_hash"`
	Revision      int64     `json:"revision"`
	Title         string    `json:"title"`
	Preview       string    `json:"preview"`
	CreatedAt     float64   `json:"created_at"`
	AssetCount    int       `json:"asset_count"`
	UploadedAt    time.Time `json:"uploaded_at"`
	ThumbnailHash string    `json:"thumbnail_hash,omitempty"`
	AudioHash     string    `json:"audio_hash,omitempty"`
}

func (h *Handler) commit(w http.ResponseWriter, r *http.Request, user auth.User) {
	r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		fail(w, 413, "manifest_too_large")
		return
	}
	var m Manifest
	if json.Unmarshal(raw, &m) != nil || m.FormatVersion != 1 || !uuidPattern.MatchString(m.PointID) || m.Revision < 1 || len(m.Title) > 4096 || len(m.Preview) > 4096 || m.CreatedAt <= 0 || len(m.Assets) > 128 || len(m.Payload) == 0 {
		fail(w, 400, "invalid_manifest")
		return
	}
	var payload struct {
		Points []struct {
			ID       string `json:"id"`
			Revision int64  `json:"head_revision"`
		} `json:"points"`
	}
	if json.Unmarshal(m.Payload, &payload) != nil || len(payload.Points) != 1 || !strings.EqualFold(payload.Points[0].ID, m.PointID) || payload.Points[0].Revision != m.Revision {
		fail(w, 400, "invalid_manifest")
		return
	}
	seen := map[string]bool{}
	for _, a := range m.Assets {
		if !uuidPattern.MatchString(a.ID) || seen[a.ID] || !hashPattern.MatchString(a.SHA256) || a.ByteCount <= 0 || a.ByteCount > maxAsset || (a.Kind != "audio" && a.Kind != "image") {
			fail(w, 400, "invalid_manifest")
			return
		}
		seen[a.ID] = true
	}
	sum := sha256.Sum256(raw)
	hash := hex.EncodeToString(sum[:])
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	tx, err := h.pool.Begin(ctx)
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "cloud:"+user.ID); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	for _, a := range m.Assets {
		var exists bool
		if err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM cloud_assets WHERE user_id=$1 AND sha256=$2 AND byte_count=$3)", user.ID, a.SHA256, a.ByteCount).Scan(&exists); err != nil {
			fail(w, 500, "storage_error")
			return
		}
		info, statErr := os.Stat(filepath.Join(h.root, user.ID, a.SHA256))
		if !exists || statErr != nil || info.Size() != a.ByteCount {
			fail(w, 409, "missing_assets")
			return
		}
	}
	var used int64
	var existing bool
	if err = tx.QueryRow(ctx, "SELECT COALESCE(sum(octet_length(manifest)),0), COALESCE(bool_or(point_id=$2::uuid AND manifest_hash=$3),false) FROM cloud_point_versions WHERE user_id=$1", user.ID, m.PointID, hash).Scan(&used, &existing); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	if !existing && used+int64(len(raw)) > 128<<20 {
		fail(w, 413, "storage_quota_exceeded")
		return
	}
	_, err = tx.Exec(ctx, `INSERT INTO cloud_point_versions(user_id,point_id,manifest_hash,revision,title,preview,created_at,manifest,asset_count) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT DO NOTHING`, user.ID, m.PointID, hash, m.Revision, m.Title, m.Preview, m.CreatedAt, raw, len(m.Assets))
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	var version Version
	err = tx.QueryRow(ctx, "SELECT point_id::text,manifest_hash,revision,title,preview,created_at,asset_count,uploaded_at FROM cloud_point_versions WHERE user_id=$1 AND point_id=$2 AND manifest_hash=$3", user.ID, m.PointID, hash).Scan(&version.PointID, &version.ManifestHash, &version.Revision, &version.Title, &version.Preview, &version.CreatedAt, &version.AssetCount, &version.UploadedAt)
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		fail(w, 500, "storage_error")
		return
	}
	write(w, 200, version)
}

type cursor struct {
	At    time.Time `json:"at"`
	Hash  string    `json:"hash"`
	Point string    `json:"point"`
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request, user auth.User) {
	var at *time.Time
	hash, point := "", "00000000-0000-0000-0000-000000000000"
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		if len(raw) > 512 {
			fail(w, 400, "invalid_cursor")
			return
		}
		data, err := base64.RawURLEncoding.DecodeString(raw)
		var c cursor
		if err != nil || json.Unmarshal(data, &c) != nil || c.At.IsZero() || !hashPattern.MatchString(c.Hash) || !uuidPattern.MatchString(c.Point) {
			fail(w, 400, "invalid_cursor")
			return
		}
		at = &c.At
		hash = c.Hash
		point = c.Point
	}
	rows, err := h.pool.Query(r.Context(), `SELECT point_id::text,manifest_hash,revision,title,preview,created_at,asset_count,uploaded_at,manifest FROM cloud_point_versions WHERE user_id=$1 AND ($2::timestamptz IS NULL OR (uploaded_at,manifest_hash,point_id)<($2,$3,$4::uuid)) ORDER BY uploaded_at DESC,manifest_hash DESC,point_id DESC LIMIT 201`, user.ID, at, hash, point)
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	defer rows.Close()
	items := []Version{}
	for rows.Next() {
		var v Version
		var manifest []byte
		if err = rows.Scan(&v.PointID, &v.ManifestHash, &v.Revision, &v.Title, &v.Preview, &v.CreatedAt, &v.AssetCount, &v.UploadedAt, &manifest); err != nil {
			fail(w, 500, "storage_error")
			return
		}
		var m Manifest
		if json.Unmarshal(manifest, &m) == nil {
			for _, a := range m.Assets {
				if a.Kind == "image" && v.ThumbnailHash == "" {
					v.ThumbnailHash = a.SHA256
				}
				if a.Kind == "audio" && v.AudioHash == "" {
					v.AudioHash = a.SHA256
				}
			}
		}
		items = append(items, v)
	}
	if rows.Err() != nil {
		fail(w, 500, "storage_error")
		return
	}
	next := ""
	if len(items) > 200 {
		items = items[:200]
		last := items[len(items)-1]
		data, _ := json.Marshal(cursor{last.UploadedAt, last.ManifestHash, last.PointID})
		next = base64.RawURLEncoding.EncodeToString(data)
	}
	write(w, 200, map[string]any{"items": items, "next_cursor": next})
}
func (h *Handler) downloadManifest(w http.ResponseWriter, r *http.Request, user auth.User) {
	point, hash := r.PathValue("point"), r.PathValue("hash")
	if !uuidPattern.MatchString(point) || !hashPattern.MatchString(hash) {
		fail(w, 400, "invalid_manifest")
		return
	}
	var data []byte
	err := h.pool.QueryRow(r.Context(), "SELECT manifest FROM cloud_point_versions WHERE user_id=$1 AND point_id=$2 AND manifest_hash=$3", user.ID, point, hash).Scan(&data)
	if errors.Is(err, pgx.ErrNoRows) {
		fail(w, 404, "not_found")
		return
	}
	if err != nil {
		fail(w, 500, "storage_error")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.json"`, point))
	_, _ = w.Write(data)
}
