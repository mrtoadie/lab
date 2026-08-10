package main

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/huh"
)

type Backup struct {
	Name        string
	Status      string
	Errors      int
	Warnings    int
	Created     string
	CreatedTime time.Time
	Expires     string
}

func executeCommand(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	return string(output), err
}

func fetchBackupsDetailed() ([]Backup, error) {
	output, err := executeCommand("velero", "backup", "get")
	if err != nil {
		fmt.Printf("⚠️  Warnung: %s\n", err)
		// --all-namespaces exists nicht, also einfach weitermachen
	}

	lines := strings.Split(strings.TrimSpace(output), "\n")
	var backups []Backup

	// Regex: NAME STATUS ERRORS WARNINGS CREATED EXPIRES
	// Datumformat: 2026-08-09 21:54:03 +0200 CEST
	re := regexp.MustCompile(`^(\S+)\s+(Completed|Failed|Partial|Pending)\s+(\d+)\s+(\d+)\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+[+-]\d{4}\s+\w+)\s+(\d+d|\d+h|\d+m)`)

	for _, line := range lines {
		line = strings.TrimSpace(line)

		// Überschriften, leere Zeilen und <none> ignorieren
		if line == "" ||
			strings.HasPrefix(line, "NAME") ||
			strings.HasPrefix(line, "<none>") ||
			strings.HasPrefix(line, "SELECTOR") {
				continue
			}

			matches := re.FindStringSubmatch(line)
			if matches == nil {
				continue
			}

			errors := 0
			warnings := 0
			fmt.Sscanf(matches[3], "%d", &errors)
			fmt.Sscanf(matches[4], "%d", &warnings)

			// Zeitstempel parsen
			createdTime, err := time.Parse("2006-01-02 15:04:05 -0700 MST", matches[5])
			if err != nil {
				fmt.Printf("⚠️  Could not parse date for %s: %s\n", matches[1], matches[5])
				continue
			}

			backups = append(backups, Backup{
				Name:        matches[1],
				Status:      matches[2],
				Errors:      errors,
				Warnings:    warnings,
				Created:     matches[5],
				CreatedTime: createdTime,
				Expires:     matches[6],
			})
	}

	// Nach Erstelldatum sortieren (neueste zuerst)
	sort.Slice(backups, func(i, j int) bool {
		return backups[i].CreatedTime.After(backups[j].CreatedTime)
	})

	return backups, nil
}

func formatBackupLabel(b Backup) string {
	dateStr := b.CreatedTime.Format("2006-01-02 15:04")

	statusEmoji := "✓"
	if b.Status == "Failed" {
		statusEmoji = "✗"
	} else if b.Status == "Partial" {
		statusEmoji = "⚠️"
	}

	errorIndicator := ""
	if b.Errors > 0 {
		errorIndicator = fmt.Sprintf(" ERR:%d", b.Errors)
	}

	warningIndicator := ""
	if b.Warnings > 0 {
		warningIndicator = fmt.Sprintf(" WRN:%d", b.Warnings)
	}

	label := fmt.Sprintf("%s | %-35s | %-8s | %s | %s%s%s",
			     statusEmoji, b.Name, b.Status, dateStr, errorIndicator, warningIndicator)
	return label
}

func main() {
	fmt.Println("🔄 Lade Backups von Velero...")

	allBackups, err := fetchBackupsDetailed()
	if err != nil {
		fmt.Printf("❌ Fehler: %s\n", err)
		os.Exit(1)
	}

	if len(allBackups) == 0 {
		fmt.Println("ℹ️  Keine Backups gefunden!")
		fmt.Println("   Hinweis: 'velero backup get' läuft im aktuellen Namespace.")
		os.Exit(0)
	}

	opts := make([]huh.Option[int], len(allBackups))
	for i, b := range allBackups {
		opts[i] = huh.NewOption(formatBackupLabel(b), i)
	}

	var selectedIndexes []int
	if err := huh.NewForm(
		huh.NewGroup(
			huh.NewMultiSelect[int]().
			Title(fmt.Sprintf("Backups zum Löschen wählen (%d verfügbar)", len(allBackups))).
			Description("Leertaste zum Markieren, Enter zum Bestätigen").
			Options(opts...).
			Limit(0).
			Value(&selectedIndexes),
		),
	).Run(); err != nil {
		fmt.Println("\n⛔ Abbruch durch Benutzer")
		os.Exit(0)
	}

	if len(selectedIndexes) == 0 {
		fmt.Println("ℹ️  Keine Backups ausgewählt")
		os.Exit(0)
	}

	// Gewählte Backups sammeln
	var selectedNames []string
	for _, idx := range selectedIndexes {
		if idx >= 0 && idx < len(allBackups) {
			selectedNames = append(selectedNames, allBackups[idx].Name)
		}
	}

	// Bestätigung
	backupList := strings.Join(selectedNames, "\n  • ")
	var confirmed bool
	if err := huh.NewForm(
		huh.NewGroup(
			huh.NewConfirm().
			Title(fmt.Sprintf("🗑️ %d Backup(s) wirklich löschen?", len(selectedNames))).
			Description(fmt.Sprintf("Ausgewählt:\n  • %s\n\n⚠️  Diese Aktion ist unwiderruflich!", backupList)).
			Value(&confirmed),
		),
	).Run(); err != nil {
		os.Exit(0)
	}

	if !confirmed {
		fmt.Println("ℹ️  Löschvorgang abgebrochen")
		os.Exit(0)
	}

	// Batch-Löschung
	fmt.Printf("\n🗑️  Lösche %d Backup(s)...\n\n", len(selectedNames))
	failed := 0
	success := 0

	for _, backupName := range selectedNames {
		fmt.Printf("  [%d/%d] %s... ", success+failed+1, len(selectedNames), backupName)

		if _, err := executeCommand("velero", "backup", "delete", backupName, "--confirm"); err != nil {
			fmt.Printf("❌ FEHLER: %v\n", err)
			failed++
		} else {
			fmt.Printf("✅ OK\n")
			success++
		}
	}

	// Zusammenfassung
	fmt.Printf("\n─────────────────────────────\n")
	if failed == 0 {
		fmt.Printf("✅ Alle %d Backups erfolgreich gelöscht!\n", success)
	} else {
		fmt.Printf("⚠️  %d/%d erfolgreich, %d fehlgeschlagen\n", success, len(selectedNames), failed)
		os.Exit(1)
	}
}
