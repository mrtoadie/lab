// alert-receiver: A lightweight webhook receiver for Grafana alerts.
//
// Receives Grafana webhook payloads (POST /alerts), prints them color-coded
// to the console, and appends them to a JSONL log file.
//
// Usage:
//   ./alert-receiver                 # listen on :8080
//   ./alert-receiver -port 9099     # custom port
//   ./alert-receiver -log alerts.jsonl
//
// Grafana Contact Point (Alerting -> Contact points -> Webhook):
//   URL: http://<toad-ip>:8080/alerts
//   Method: POST
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

// ---- Grafana webhook payload structures ----
// Reference: https://grafana.com/docs/grafana/latest/alerting/configure-notifications/manage-contact-points/integrations/webhook/

type Alert struct {
	Status       string            `json:"status"`
	Labels       map[string]string `json:"labels"`
	Annotations  map[string]string `json:"annotations"`
	StartsAt     string            `json:"startsAt"`
	EndsAt       string            `json:"endsAt"`
	GeneratorURL string            `json:"generatorURL"`
	Fingerprint  string            `json:"fingerprint"`
	ValueString  string            `json:"valueString"`
}

type WebhookPayload struct {
	Receiver string  `json:"receiver"`
	Status   string  `json:"status"`
	Alerts   []Alert `json:"alerts"`
	CommonLabels   map[string]string `json:"commonLabels"`
	CommonAnnotations map[string]string `json:"commonAnnotations"`
	ExternalURL    string           `json:"externalURL"`
	Title          string           `json:"title"`
	Message        string           `json:"message"`
}

// ---- ANSI colors ----
const (
	ColRed    = "\033[31m"
	ColGreen  = "\033[32m"
	ColYellow = "\033[33m"
	ColCyan   = "\033[36m"
	ColBold   = "\033[1m"
	ColReset  = "\033[0m"
)

// ---- JSONL log writer (thread-safe) ----
type AlertLog struct {
	mu   sync.Mutex
	file *os.File
}

func NewAlertLog(path string) (*AlertLog, error) {
	if path == "" {
		return nil, nil // logging disabled
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return nil, err
	}
	return &AlertLog{file: f}, nil
}

func (l *AlertLog) Append(p WebhookPayload) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()

	entry := map[string]interface{}{
		"timestamp": time.Now().Format(time.RFC3339),
		"title":     p.Title,
		"status":    p.Status,
		"message":   p.Message,
		"alerts":    p.Alerts,
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return
	}
	l.file.Write(append(data, '\n'))
}

// ---- Handlers ----

func handleAlerts(logWriter *AlertLog) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var payload WebhookPayload
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			log.Printf("%s[decode error]%s %v", ColRed, ColReset, err)
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}

		// Header line
		statusColor := ColRed
		icon := "FIRING"
		if payload.Status == "resolved" {
			statusColor = ColGreen
			icon = "RESOLVED"
		}

		ts := time.Now().Format("15:04:05")
		fmt.Printf("%s[%s]%s %s%s%s (%d alerts)\n",
			statusColor, icon, ColReset, ColBold, ts, ColReset, len(payload.Alerts))

		if payload.Title != "" {
			fmt.Printf("  %sTitle:%s %s\n", ColCyan, ColReset, payload.Title)
		}
		if payload.Message != "" {
			fmt.Printf("  %sMsg:%s   %s\n", ColCyan, ColReset, payload.Message)
		}

		// Individual alerts
		for _, a := range payload.Alerts {
			name := a.Labels["alertname"]
			if name == "" {
				name = a.Fingerprint
			}
			sev := a.Labels["severity"]
			fmt.Printf("  %s- %s%s severity=%s starts=%s\n",
				ColYellow, name, ColReset, sev, a.StartsAt)
		}
		fmt.Println()

		logWriter.Append(payload)

		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("healthy"))
}

func main() {
	port := flag.Int("port", 8080, "listen port")
	logPath := flag.String("log", "alerts.jsonl", "JSONL log file (empty to disable)")
	flag.Parse()

	logWriter, err := NewAlertLog(*logPath)
	if err != nil {
		log.Fatalf("cannot open log file: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/alerts", handleAlerts(logWriter))
	mux.HandleFunc("/health", handleHealth)

	addr := fmt.Sprintf(":%d", *port)
	fmt.Printf("%salert-receiver%s listening on %s%s/alerts%s\n",
		ColBold+ColCyan, ColReset, ColGreen, addr, ColReset)

	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
