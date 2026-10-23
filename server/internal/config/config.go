package config

import (
	"fmt"
	"net"
	"os"
	"strings"
)

type Config struct {
	HTTPAddr, DatabaseURL, CloudStorageDir  string
	AIUpstreamURL, AIUpstreamToken, AIModel string
	GoogleClientIDs, AppleClientIDs         []string
	TrustedProxyIP                          string
}

func Load() (Config, error) {
	c := Config{HTTPAddr: os.Getenv("HTTP_ADDR"), DatabaseURL: os.Getenv("DATABASE_URL")}
	if c.HTTPAddr == "" {
		c.HTTPAddr = ":8080"
	}
	if c.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	c.CloudStorageDir = os.Getenv("CLOUD_STORAGE_DIR")
	if c.CloudStorageDir == "" {
		c.CloudStorageDir = "data/cloud"
	}
	c.AIUpstreamURL = strings.TrimSpace(os.Getenv("AI_UPSTREAM_URL"))
	c.AIUpstreamToken = strings.TrimSpace(os.Getenv("AI_UPSTREAM_TOKEN"))
	c.AIModel = strings.TrimSpace(os.Getenv("AI_MODEL"))
	if c.AIUpstreamURL != "" && c.AIModel == "" {
		return Config{}, fmt.Errorf("AI_MODEL is required when AI_UPSTREAM_URL is set")
	}
	c.GoogleClientIDs = clientIDs(os.Getenv("GOOGLE_CLIENT_IDS"))
	c.AppleClientIDs = clientIDs(os.Getenv("APPLE_CLIENT_IDS"))
	c.TrustedProxyIP = os.Getenv("TRUSTED_PROXY_IP")
	if c.TrustedProxyIP != "" && net.ParseIP(c.TrustedProxyIP) == nil {
		return Config{}, fmt.Errorf("TRUSTED_PROXY_IP must be an IP address")
	}
	return c, nil
}

func clientIDs(raw string) []string {
	var ids []string
	for _, id := range strings.Split(raw, ",") {
		if id = strings.TrimSpace(id); id != "" {
			ids = append(ids, id)
		}
	}
	return ids
}
