package main

import (
	"fmt"
	"time"
)

func SimpleSpinner(msg string, stopChan <-chan struct{}) {
	go func() {
		chars := []rune{'⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'}
		//chars := []string{"⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"}
		//chars := []rune{'▁','▂','▃','▄','▅','▆','▇','█'}
		i := 0
		for {
			select {
			case <-stopChan:
				fmt.Print("\r")
				return
			default:
				fmt.Printf("\r%s %c ", msg, chars[i%len(chars)])
				time.Sleep(100 * time.Millisecond)
				i++
			}
		}
	}()
}

func SimpleSpinner2(msg string, stopChan <-chan struct{}) {
	go func() {
		//chars := []string{"⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"}
		chars := []rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}
		i := 0
		for {
			select {
			case <-stopChan:
				fmt.Print("\r")
				return
			default:
				fmt.Printf("\r%s %c ", msg, chars[i%len(chars)])
				time.Sleep(100 * time.Millisecond)
				i++
			}
		}
	}()
}

func SimpleSpinner3(msg string, stopChan <-chan struct{}) {
	go func() {
		chars := []string{"⣾⣽", "⣻⢿", "⡿⣟", "⣯⣷"}
		i := 0
		for {
			select {
			case <-stopChan:
				fmt.Print("\r")
				return
			default:
				fmt.Printf("\r%s %s ", msg, chars[i%len(chars)])
				time.Sleep(100 * time.Millisecond)
				i++
			}
		}
	}()
}

func main() {

	for {
		// Mainmenu
		fmt.Println("\n=== Mainmenu ===")
		fmt.Println("[1] Spinner 1")
		fmt.Println("[2] Spinner 2")
		fmt.Println("[3] Spinner 3")
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
			stop := make(chan struct{})
			SimpleSpinner("\x1b[34mSpinner:", stop)
			time.Sleep(2 * time.Second)
			fmt.Println("\x1b[0m")
			// stopp progessbar
			close(stop)
		case 2:
			stop := make(chan struct{})
			SimpleSpinner2("\x1b[34mSpinner:", stop)
			time.Sleep(2 * time.Second)
			fmt.Println("\x1b[0m")
			// stopp progessbar
			close(stop)
		case 3:
			stop := make(chan struct{})
			SimpleSpinner3("\x1b[34mSpinner:", stop)
			time.Sleep(2 * time.Second)
			fmt.Println("\x1b[0m")
			// stopp progessbar
			close(stop)
		default:
			fmt.Println("Invalid selection.")
		}
	}
}
