package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"time"

	"vel-go/internal/backup"
	"vel-go/internal/config"
	"vel-go/internal/logger"
	"vel-go/internal/ui"
)

func main() {
	flags, _ := config.ParseFlags()

	cfg, err := config.ConfigFromFlags(flags)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Fehler bei Konfiguration: %v\n", err)
		os.Exit(1)
	}

	configPath, _ := config.GetConfigPath()
	if savedCfg, err := config.LoadFromFile(configPath); err == nil {
		cfg = mergeConfigs(savedCfg, cfg)
	}

	logLevel := logger.ParseLevel(cfg.LogLevel)

	var log *logger.Logger
	if cfg.LogFile != "" {
		log, err = logger.NewFile(cfg.LogFile, logLevel)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Fehler beim Erstellen des Logs: %v\n", err)
			os.Exit(1)
		}
		defer log.Close()
	} else {
		log = logger.New(os.Stdout, logLevel)
	}

	ctx := context.Background()

	client := backup.NewClient(cfg.VeleroBinary, backup.WithLogger(log))

	if err := client.IsAvailable(); err != nil {
		ui.ShowError("Velero nicht erreichbar oder nicht installiert")
		log.Error("Velero availability check failed")
		os.Exit(1)
	}

	version, _ := client.CheckVersion()
	if version != "" {
		ui.ShowInfo("Velero Version", version)
	}

	ui.ShowLoading("Lade Backups...")

	startTime := time.Now()
	backups, err := client.ListBackups(ctx, cfg.Namespace, cfg.ShowAllNamespaces)
	loadDuration := time.Since(startTime)

	if err != nil {
		ui.ShowError(fmt.Sprintf("Fehler beim Laden: %v", err))
		log.Error("ListBackups failed")
		os.Exit(1)
	}

	log.Info("Backups geladen")
	log.LogAction("load_backups", "", loadDuration, true)

	backups = backup.Deduplicate(backups)
	backups = backup.FilterByStatus(backups, cfg.StatusFilters)

	if cfg.MaxBackups > 0 && len(backups) > cfg.MaxBackups {
		backups = backups[:cfg.MaxBackups]
	}

	sort.Slice(backups, func(i, j int) bool {
		return backups[i].Created.After(backups[j].Created)
	})

	if len(backups) == 0 {
		ui.ShowInfo("Keine Backups gefunden",
			    fmt.Sprintf("Namespace: %s | Filter: %v", cfg.Namespace, cfg.StatusFilters))
		os.Exit(0)
	}

	ui.ShowInfo(fmt.Sprintf("%d Backups gefunden", len(backups)), "")

	selectedIndexes := ui.SelectBackups(backups, 0)

	if selectedIndexes == nil || len(selectedIndexes) == 0 {
		ui.ShowInfo("Keine Backups ausgewählt", "Abbruch")
		os.Exit(0)
	}

	var selectedNames []string
	for _, idx := range selectedIndexes {
		if idx >= 0 && idx < len(backups) {
			selectedNames = append(selectedNames, backups[idx].Name)
		}
	}

	ui.ShowPreview(selectedNames, cfg.DryRun)

	if !cfg.DryRun {
		if !ui.ConfirmDeletion(selectedNames) {
			ui.ShowInfo("Löschvorgang abgebrochen", "")
			os.Exit(0)
		}
	}

	deleteStart := time.Now()
	result := client.BatchDelete(ctx, selectedNames, cfg.DryRun, cfg.AllowPartial)
	deleteDuration := time.Since(deleteStart)

	if cfg.DryRun {
		ui.ShowInfo("Trockenausführung abgeschlossen",
			    fmt.Sprintf("Vorgesehene Löschung von %d Backup(s)", result.Total))
	} else {
		ui.ShowSummary(result)
	}

	log.LogAction("batch_delete", "", deleteDuration, result.Failed == 0)

	if result.Failed > 0 && !cfg.AllowPartial && !cfg.DryRun {
		os.Exit(1)
	}
}

func mergeConfigs(saved *config.Config, current *config.Config) *config.Config {
	merged := *saved

	def := config.DefaultConfig()

	if current.VeleroBinary != def.VeleroBinary {
		merged.VeleroBinary = current.VeleroBinary
	}
	if current.Namespace != "" {
		merged.Namespace = current.Namespace
	}
	if current.ShowAllNamespaces {
		merged.ShowAllNamespaces = current.ShowAllNamespaces
	}
	if len(current.StatusFilters) > 0 {
		merged.StatusFilters = current.StatusFilters
	}
	if current.DryRun {
		merged.DryRun = current.DryRun
	}
	if current.AllowPartial {
		merged.AllowPartial = current.AllowPartial
	}
	if current.LogLevel != def.LogLevel {
		merged.LogLevel = current.LogLevel
	}
	if current.LogFile != "" {
		merged.LogFile = current.LogFile
	}
	if current.MaxBackups > 0 {
		merged.MaxBackups = current.MaxBackups
	}

	return &merged
}
