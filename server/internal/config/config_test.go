package config

import "testing"

func TestLoad(t *testing.T) {
	t.Setenv("HTTP_ADDR", "")
	t.Setenv("DATABASE_URL", "")
	if _, err := Load(); err == nil {
		t.Fatal("missing database URL accepted")
	}
	t.Setenv("DATABASE_URL", "postgres://example")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.HTTPAddr != ":8080" {
		t.Fatalf("unexpected address %s", cfg.HTTPAddr)
	}
	t.Setenv("HTTP_ADDR", "127.0.0.1:9000")
	cfg, err = Load()
	if err != nil || cfg.HTTPAddr != "127.0.0.1:9000" {
		t.Fatalf("override not applied: %v %v", cfg, err)
	}
}

func TestProviderClientIDs(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("GOOGLE_CLIENT_IDS", " web-client, ios-client , ,")
	t.Setenv("APPLE_CLIENT_IDS", "")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.GoogleClientIDs) != 2 || cfg.GoogleClientIDs[0] != "web-client" || cfg.GoogleClientIDs[1] != "ios-client" {
		t.Fatalf("incorrect IDs: %v", cfg.GoogleClientIDs)
	}
	if len(cfg.AppleClientIDs) != 0 {
		t.Fatal("unconfigured Apple provider enabled")
	}
}
