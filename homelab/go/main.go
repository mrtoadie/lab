package main

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"

	"github.com/charmbracelet/huh"
)

type Backup struct {
	Name      string
	Namespace string
	Status    string
	Created   string
	Expires   string
	Volumes   int
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
		output, _ = executeCommand("velero", "backup", "get", "--all-namespaces")
	}

	lines := strings.Split(strings.TrimSpace(output), "\n")
	var backups []Backup

	// Regex: NAME NAMESPACE STATUS CREATED EXPIRES VOLUMES
	re := regexp.MustCompile(`^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)`)

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "NAME") || strings.HasPrefix(line, "{") {
			continue
		}

		matches := re.FindStringSubmatch(line)
		if matches == nil {
			continue
		}

		volumes := 0
		fmt.Sscanf(matches[6], "%d", &volumes)

		backups = append(backups, Backup{
			Name:      matches[1],
			Namespace: matches[2],
			Status:    matches[3],
			Created:   matches[4],
			Expires:   matches[5],
			Volumes:   volumes,
		})
	}

	sort.Slice(backups, func(i, j int) bool {
		return backups[i].Created > backups[j].Created
	})

	return backups, nil
}

func getStatusFilter() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("Alle", "all"),
		huh.NewOption("Completed ✓", "completed"),
		huh.NewOption("PartiallyFailed ⚠️", "partial"),
		huh.NewOption("Failed ✗", "failed"),
	}
}

func filterBackups(backups []Backup, status string) []Backup {
	if status == "all" {
		return backups
	}

	filtered := make([]Backup, 0)
	statusLower := strings.ToLower(status)

	for _, b := range backups {
		if strings.Contains(strings.ToLower(b.Status), statusLower) {
			filtered = append(filtered, b)
		}
	}

	return filtered
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
		os.Exit(0)
	}

	// 1. Status Filter wählen
	var statusFilter string
	if err := huh.NewForm(
		huh.NewGroup(
			huh.NewSelect[string]().
			Title("Backup Status Filter").
			Options(getStatusFilter()...).
			Value(&statusFilter),
		),
	).Run(); err != nil {
		fmt.Println("\n⛔ Abbruch")
		os.Exit(0)
	}

	filteredBackups := filterBackups(allBackups, statusFilter)

	if len(filteredBackups) == 0 {
		fmt.Println("ℹ️  Keine Backups mit diesem Status gefunden")
		os.Exit(0)
	}

	// 2. Backup auswählen
	var selectedBackup string
	if err := huh.NewForm(
		huh.NewGroup(
			huh.NewSelect[string]().
			Title(fmt.Sprintf("Backup zum Löschen wählen (%d)", len(filteredBackups))).
			Options(func() []huh.Option[string] {
				opts := make([]huh.Option[string], len(filteredBackups))
				for i, b := range filteredBackups {
					label := fmt.Sprintf("✂️ %s (%s) | %s | Vol:%d",
							     b.Name, b.Namespace, b.Status, b.Volumes)
					opts[i] = huh.NewOption(label, b.Name)
				}
				return opts
			}()...).
			Value(&selectedBackup),
		),
	).Run(); err != nil {
		fmt.Println("\n⛔ Abbruch durch Benutzer")
		os.Exit(0)
	}

	// 3. Bestätigung - HIER KORRIGIERT mit fmt.Sprintf()
	var confirmed bool
	if err := huh.NewForm(
		huh.NewGroup(
			huh.NewConfirm().
			Title(fmt.Sprintf("🗑️ '%s' wirklich löschen?", selectedBackup)). // <- fmt.Sprintf() statt .format()
		Description("Achtung: Diese Aktion ist unwiderruflich!").
		Value(&confirmed),
		),
	).Run(); err != nil {
		os.Exit(0)
	}

	if !confirmed {
		fmt.Println("ℹ️  Löschvorgang abgebrochen")
		os.Exit(0)
	}

	// 4. Löschen
	fmt.Printf("\n🗑️  Lösche Backup '%s'...\n", selectedBackup)
	if _, err := executeCommand("velero", "backup", "delete", selectedBackup, "--confirm"); err != nil {
		fmt.Printf("❌ Fehler beim Löschen: %s\n", err)
		os.Exit(1)
	}

	fmt.Printf("✅ Backup '%s' erfolgreich gelöscht!\n", selectedBackup)
}
