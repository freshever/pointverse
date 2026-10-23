package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"pointverse/server/internal/ai"
	"pointverse/server/internal/auth"
	"pointverse/server/internal/cloud"
	"pointverse/server/internal/config"
	"pointverse/server/internal/database"
	"pointverse/server/internal/httpapi"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(); err != nil {
		slog.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	startup, cancel := context.WithTimeout(ctx, 10*time.Second)
	pool, err := database.Open(startup, cfg.DatabaseURL)
	cancel()
	if err != nil {
		return err
	}
	defer pool.Close()
	providers := auth.NewProviders(ctx, cfg.GoogleClientIDs, cfg.AppleClientIDs)
	authentication := auth.NewHandler(auth.NewStore(pool), providers)
	cloudStorage, err := cloud.New(pool, cfg.CloudStorageDir, authentication)
	if err != nil {
		return err
	}
	aiService, err := ai.New(cfg.AIUpstreamURL, cfg.AIUpstreamToken, cfg.AIModel, authentication)
	if err != nil {
		return err
	}
	slog.Info("login providers configured", "google", providers.Enabled("google"), "apple", providers.Enabled("apple"))
	server := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           httpapi.TrustedProxy(httpapi.New(func(ctx context.Context) error { return database.Ready(ctx, pool) }, authentication, cloudStorage, aiService), cfg.TrustedProxyIP),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Minute,
		WriteTimeout: 5 * time.Minute, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 1 << 20,
	}
	failures := make(chan error, 1)
	go func() { failures <- server.ListenAndServe() }()
	slog.Info("server starting", "address", cfg.HTTPAddr)
	select {
	case err := <-failures:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			_ = server.Close()
			return err
		}
		return nil
	}
}
