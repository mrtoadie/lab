package main

import (
	"fmt"
)

func main() {
	for {
		// Mainmenu
		fmt.Println("\n=== Mainmenu ===")
		fmt.Println("[1] Menu A")
		fmt.Println("[2] Menu B")
		fmt.Println("[3] Menu C")
		fmt.Println("[4] Menu D")
		fmt.Println("[0] Exit")
		var choice int
		fmt.Print("Selection: ")
		if _, err := fmt.Scanln(&choice); err != nil {
			fmt.Println("Please enter a valid number.")
			continue
		}

		switch choice {
		case 0:
			fmt.Println("Bye!")
			return
		case 1:
			subMenu("A")
		case 2:
			subMenu("B")
		case 3:
			subMenu("C")
		case 4:
			subMenu("D")
		default:
			fmt.Println("Invalid selection.")
		}
	}
}

// Submenu (identical for A–D)
func subMenu(label string) {
	for {
		fmt.Printf("\n--- Menu %s ---\n", label)
		fmt.Printf("[1] Submenu %s‑1\n", label)
		fmt.Printf("[2] Submenu %s‑2\n", label)
		fmt.Println("[0] Back")
		var sub int
		fmt.Print("Selection: ")
		if _, err := fmt.Scanln(&sub); err != nil {
			fmt.Println("Please enter a valid number.")
			continue
		}
		switch sub {
		case 0:
			return // zurück zum Hauptmenü
		case 1:
			fmt.Printf("▶ Action %s‑1 executed\n", label)
		case 2:
			fmt.Printf("▶ Action %s‑2 executed\n", label)
		default:
			fmt.Println("Invalid selection.")
		}
	}
}