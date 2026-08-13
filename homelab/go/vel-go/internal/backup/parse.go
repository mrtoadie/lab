package backup

import (
	"bufio"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var (
	statusPattern = regexp.MustCompile(`^(Completed|Failed|Partial|Pending|Deleting)$`)
	expiryPattern = regexp.MustCompile(`^(\d+)d$|^(\d+)h$|^(\d+)m$`)
)

func ParseTimestamp(dateStr string) (time.Time, error) {
	formats := []string{
		"2006-01-02 15:04:05 -0700 MST",
		"2006-01-02 15:04:05 +0200 CEST",
		"2006-01-02 15:04:05 -0700 UTC",
		"2006-01-02 15:04:05 +0000 UTC",
	}

	dateStr = strings.TrimSpace(dateStr)

	for _, format := range formats {
		if t, err := time.Parse(format, dateStr); err == nil {
			return t, nil
		}
	}

	return time.Time{}, fmt.Errorf("unsupported timestamp format: %s", dateStr)
}

func parseExpiry(expiryStr string) string {
	match := expiryPattern.FindStringSubmatch(expiryStr)
	if match == nil {
		return expiryStr
	}

	if match[1] != "" {
		days, _ := strconv.Atoi(match[1])
		return fmt.Sprintf("%dd", days)
	}
	if match[2] != "" {
		hours, _ := strconv.Atoi(match[2])
		return fmt.Sprintf("%dh", hours)
	}
	if match[3] != "" {
		minutes, _ := strconv.Atoi(match[3])
		return fmt.Sprintf("%dm", minutes)
	}

	return expiryStr
}

func ParseBackupLine(line string) (*Backup, error) {
	line = strings.TrimSpace(line)

	if line == "" ||
		strings.HasPrefix(line, "NAME") ||
		strings.HasPrefix(line, "<none>") ||
		strings.HasPrefix(line, "SELECTOR") ||
		strings.HasPrefix(line, "Namespace:") {
			return nil, nil
		}

		parts := strings.Fields(line)
		if len(parts) < 6 {
			return nil, fmt.Errorf("insufficient fields: %d", len(parts))
		}

		name := parts[0]
		statusStr := parts[1]

		if !statusPattern.MatchString(statusStr) {
			return nil, fmt.Errorf("invalid status: %s", statusStr)
		}

		status := Status(statusStr)

		errors := 0
		warnings := 0

		if len(parts) >= 3 {
			if e, err := strconv.Atoi(parts[2]); err == nil {
				errors = e
			}
		}

		if len(parts) >= 4 {
			if w, err := strconv.Atoi(parts[3]); err == nil {
				warnings = w
			}
		}

		dateStart := 4
		dateEnd := 6

		if len(parts) < dateEnd {
			return nil, fmt.Errorf("insufficient date fields")
		}

		dateStr := strings.Join(parts[dateStart:dateEnd], " ")
		createdTime, err := ParseTimestamp(dateStr)
		if err != nil {
			return nil, err
		}

		expiryStr := ""
		if len(parts) >= dateEnd+1 {
			expiryStr = parseExpiry(parts[dateEnd])
		}

		return &Backup{
			Name:      name,
			Status:    status,
			Errors:    errors,
			Warnings:  warnings,
			Created:   createdTime,
			ExpiresIn: expiryStr,
		}, nil
}

func ParseOutput(output string) ([]*Backup, error) {
	var backups []*Backup
	scanner := bufio.NewScanner(strings.NewReader(output))

	for scanner.Scan() {
		line := scanner.Text()

		b, err := ParseBackupLine(line)
		if err != nil {
			continue
		}
		if b != nil {
			backups = append(backups, b)
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	// Nach Erstelldatum sortieren (neueste zuerst)
	sort.Slice(backups, func(i, j int) bool {
		return backups[i].Created.After(backups[j].Created)
	})

	return backups, nil
}

func FilterByStatus(backups []*Backup, statuses []string) []*Backup {
	if len(statuses) == 0 {
		return backups
	}

	statusMap := make(map[string]bool)
	for _, s := range statuses {
		statusMap[s] = true
	}

	var filtered []*Backup
	for _, b := range backups {
		if statusMap[string(b.Status)] {
			filtered = append(filtered, b)
		}
	}

	return filtered
}

func FilterByAge(backups []*Backup, maxAgeDays int) []*Backup {
	if maxAgeDays <= 0 {
		return backups
	}

	var filtered []*Backup
	for _, b := range backups {
		age := int(time.Since(b.Created).Hours() / 24)
		if age <= maxAgeDays {
			filtered = append(filtered, b)
		}
	}

	return filtered
}

func Deduplicate(backups []*Backup) []*Backup {
	seen := make(map[string]bool)
	var unique []*Backup

	for _, b := range backups {
		if !seen[b.Name] {
			seen[b.Name] = true
			unique = append(unique, b)
		}
	}

	return unique
}
