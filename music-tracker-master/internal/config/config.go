package config

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type AppConfig struct {
	DownloadPath string `json:"downloadPath"`
	AudioQuality string `json:"audioQuality"`
	AudioFormat  string `json:"audioFormat"`
	DownloadFrom string `json:"downloadFrom"`
}

func GetConfigPath() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}

	appDir := filepath.Join(configDir, "music-tracker")
	if err := os.MkdirAll(appDir, 0755); err != nil {
		return "", err
	}

	return filepath.Join(appDir, "config.json"), nil
}

func LoadConfig() (AppConfig, error) {
	cfg := AppConfig{
		DownloadPath: "../../downloads",
		AudioFormat:  "mp3",
		AudioQuality: "very_high",
		DownloadFrom: "",
	}

	path, err := GetConfigPath()
	if err != nil {
		return cfg, nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		SaveConfig(cfg)
		return cfg, nil
	}

	err = json.Unmarshal(data, &cfg)
	return cfg, err
}

func SaveConfig(cfg AppConfig) error {
	path, err := GetConfigPath()
	if err != nil {
		return err
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}
