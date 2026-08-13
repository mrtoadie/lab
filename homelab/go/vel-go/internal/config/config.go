package config

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Config struct {
	VeleroBinary      string        `json:"velero_binary"`
	Namespace         string        `json:"namespace"`
	ShowAllNamespaces bool          `json:"show_all_namespaces"`
	StatusFilters     []string      `json:"status_filters"`
	DryRun            bool          `json:"dry_run"`
	AllowPartial      bool          `json:"allow_partial"`
	LogLevel          string        `json:"log_level"`
	LogFile           string        `json:"log_file"`
	MaxBackups        int           `json:"max_backups"`
	RefreshInterval   time.Duration `json:"refresh_interval"`
}

type ConfigFlags struct {
	VeleroBinary      *string
	Namespace         *string
	ShowAllNamespaces *bool
	StatusFilters     *string
	DryRun            *bool
	AllowPartial      *bool
	LogLevel          *string
	LogFile           *string
	MaxBackups        *int
	RefreshInterval   *string
}

func NewConfigFlags() *ConfigFlags {
	return &ConfigFlags{
		VeleroBinary: flag.String(
			"binary",
			"velero",
			"Pfad zur Velero-Binary",
		),
		Namespace: flag.String(
			"namespace",
			 "",
			 "Velero-Namespace (leer für alle)",
		),
		ShowAllNamespaces: flag.Bool(
			"A",
			false,
			"Alle Namespaces anzeigen (--all-namespaces)",
		),
		StatusFilters: flag.String(
			"status",
			"",
			"Status filter (comma-separated: Completed,Failed,Partial)",
		),
		DryRun: flag.Bool(
			"dry-run",
		    false,
		    "Nur anzeigen, was gelöscht würde",
		),
		AllowPartial: flag.Bool(
			"allow-partial",
			false,
			"Zulassen, dass einige Deletes fehlschlagen",
		),
		LogLevel: flag.String(
			"log-level",
			"info",
			"Log-Level: debug, info, warn, error",
		),
		LogFile: flag.String(
			"log-file",
		       "",
		       "Log-Datei (leer für stdout)",
		),
		MaxBackups: flag.Int(
			"max",
		       0,
		       "Maximale Anzahl Backups anzeigen (0 = unbegrenzt)",
		),
		RefreshInterval: flag.String(
			"refresh",
			"",
			"Auto-refresh Intervall (z.B. 30s, 5m)",
		),
	}
}

func ParseFlags() (*ConfigFlags, []string) {
	flag.Usage = func() {
		println(`
		Velero TUI - Backup Management mit Terminal UI

		USAGE:
		velero-tui [OPTIONS]

		OPTIONS:
		-binary PATH      Pfad zur Velero-Binary (default: velero)
		-namespace NS     Namespace filter (leer für aktuellen Namespace)
		-A                Alle Namespaces anzeigen (--all-namespaces)
		-status LIST      Status filter (comma-separated: Completed,Failed,Partial)
		-dry-run          Nur Preview ohne Ausführung
		-allow-partial    Teilweise Erfolge zulassen
		-log-level LEVEL  Log-Level: debug|info|warn|error
		-log-file PATH    Log-Datei (default: stdout)
		-max N            Maximale Backups anzeigen
		-refresh DURATION Auto-refresh Intervall

		EXAMPLES:
		velero-tui -namespace production -status Completed,Partial
		velero-tui -A --dry-run
		velero-tui -max 20 --refresh 5m
		`)
	}

	flag.Parse()
	return NewConfigFlags(), flag.Args()
}

func LoadFromFile(path string) (*Config, error) {
	config := DefaultConfig()

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return config, nil
		}
		return nil, err
	}

	if err := json.Unmarshal(data, config); err != nil {
		return nil, err
	}

	return config, nil
}

func DefaultConfig() *Config {
	return &Config{
		VeleroBinary:      "velero",
		Namespace:         "",
		ShowAllNamespaces: false,
		StatusFilters:     []string{"Completed", "Failed", "Partial"},
		DryRun:            false,
		AllowPartial:      false,
		LogLevel:          "info",
		LogFile:           "",
		MaxBackups:        0,
		RefreshInterval:   0,
	}
}

func ConfigFromFlags(flags *ConfigFlags) (*Config, error) {
	config := DefaultConfig()

	if flags.VeleroBinary != nil && *flags.VeleroBinary != "" {
		config.VeleroBinary = *flags.VeleroBinary
	}

	if flags.Namespace != nil && *flags.Namespace != "" {
		config.Namespace = *flags.Namespace
	}

	if flags.ShowAllNamespaces != nil {
		config.ShowAllNamespaces = *flags.ShowAllNamespaces
	}

	if flags.StatusFilters != nil && *flags.StatusFilters != "" {
		config.StatusFilters = splitString(*flags.StatusFilters)
	}

	if flags.DryRun != nil {
		config.DryRun = *flags.DryRun
	}

	if flags.AllowPartial != nil {
		config.AllowPartial = *flags.AllowPartial
	}

	if flags.LogLevel != nil && *flags.LogLevel != "" {
		config.LogLevel = *flags.LogLevel
	}

	if flags.LogFile != nil && *flags.LogFile != "" {
		config.LogFile = *flags.LogFile
	}

	if flags.MaxBackups != nil {
		config.MaxBackups = *flags.MaxBackups
	}

	if flags.RefreshInterval != nil && *flags.RefreshInterval != "" {
		if dur, err := time.ParseDuration(*flags.RefreshInterval); err == nil {
			config.RefreshInterval = dur
		}
	}

	return config, nil
}

func splitString(s string) []string {
	parts := strings.Split(s, ",")
	result := make([]string, 0, len(parts))

	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			result = append(result, part)
		}
	}

	return result
}

func GetConfigPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "velero-tui", "config.json"), nil
}

func SaveConfig(config *Config) error {
	path, err := GetConfigPath()
	if err != nil {
		return err
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}
