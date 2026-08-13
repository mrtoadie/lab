package logger

import (
	"encoding/json"
	"io"
	"os"
	"sync"
	"time"
)

type Level int

const (
	DebugLevel Level = iota
	InfoLevel
	WarnLevel
	ErrorLevel
)

func ParseLevel(s string) Level {
	switch s {
		case "debug":
			return DebugLevel
		case "info":
			return InfoLevel
		case "warn", "warning":
			return WarnLevel
		case "error":
			return ErrorLevel
		default:
			return InfoLevel
	}
}

func (l Level) String() string {
	switch l {
		case DebugLevel:
			return "DEBUG"
		case InfoLevel:
			return "INFO"
		case WarnLevel:
			return "WARN"
		case ErrorLevel:
			return "ERROR"
		default:
			return "UNKNOWN"
	}
}

type Entry struct {
	Timestamp  time.Time       `json:"timestamp"`
	Level      string          `json:"level"`
	Message    string          `json:"message"`
	Action     string          `json:"action,omitempty"`
	BackupName string          `json:"backup,omitempty"`
	DurationMs int64           `json:"duration_ms,omitempty"`
	Success    bool            `json:"success,omitempty"`
	Extra      map[string]interface{} `json:"extra,omitempty"`
}

type Logger struct {
	mu        sync.Mutex
	out       io.Writer
	level     Level
	file      *os.File
	closeFile bool
}

func New(out io.Writer, level Level) *Logger {
	return &Logger{
		out:   out,
		level: level,
	}
}

func NewFile(logFile string, level Level) (*Logger, error) {
	file, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return nil, err
	}

	return &Logger{
		out:       file,
		level:     level,
		file:      file,
		closeFile: true,
	}, nil
}

func (l *Logger) Close() error {
	if l.closeFile && l.file != nil {
		return l.file.Close()
	}
	return nil
}

func (l *Logger) log(level Level, msg string, args ...interface{}) {
	if level < l.level {
		return
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	entry := Entry{
		Timestamp: time.Now().UTC(),
		Level:     level.String(),
		Message:   msg,
	}

	jsonData, _ := json.Marshal(entry)
	l.out.Write(jsonData)
	l.out.Write([]byte("\n"))
}

func (l *Logger) Debug(msg string, args ...interface{}) {
	l.log(DebugLevel, msg, args...)
}

func (l *Logger) Info(msg string, args ...interface{}) {
	l.log(InfoLevel, msg, args...)
}

func (l *Logger) Warn(msg string, args ...interface{}) {
	l.log(WarnLevel, msg, args...)
}

func (l *Logger) Error(msg string, args ...interface{}) {
	l.log(ErrorLevel, msg, args...)
}

func (l *Logger) Fatal(msg string, args ...interface{}) {
	l.log(ErrorLevel, msg, args...)
	os.Exit(1)
}

func (l *Logger) LogAction(action string, backupName string, duration time.Duration, success bool) {
	l.mu.Lock()
	defer l.mu.Unlock()

	entry := Entry{
		Timestamp:  time.Now().UTC(),
		Level:      InfoLevel.String(),
		Action:     action,
		BackupName: backupName,
		DurationMs: duration.Milliseconds(),
		Success:    success,
	}

	jsonData, _ := json.Marshal(entry)
	l.out.Write(jsonData)
	l.out.Write([]byte("\n"))
}

func (l *Logger) LogError(action string, backupName string, err error) {
	l.mu.Lock()
	defer l.mu.Unlock()

	entry := Entry{
		Timestamp:  time.Now().UTC(),
		Level:      ErrorLevel.String(),
		Message:    err.Error(),
		Action:     action,
		BackupName: backupName,
	}

	jsonData, _ := json.Marshal(entry)
	l.out.Write(jsonData)
	l.out.Write([]byte("\n"))
}
