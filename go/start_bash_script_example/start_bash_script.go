package main

import (
	"fmt"
	"os/exec"
	"time"
)

func main() {
	// path to bash script
	scriptPath := "/my_script.sh"

	// start time
	start := time.Now()

	// run bash
	cmd := exec.Command("bash", scriptPath)

	if err := cmd.Run(); err != nil {
		// error handling (i.e. non‑zero exit‑code)
		fmt.Printf("Error: %v\n", err)
		return
	}

	// end time
	elapsed := time.Since(start)

	fmt.Printf("Script runtime %s\n", elapsed)
}