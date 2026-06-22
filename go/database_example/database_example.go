//
//  _____               _ _       
// |_   _|__   __ _  __| (_) ___  
//   | |/ _ \ / _` |/ _` | |/ _ \ 
//   | | (_) | (_| | (_| | |  __/ 
//   |_|\___/ \__,_|\__,_|_|\___| 
//
// Autor: Toadie
// Modified: 17. Oktober 2025
// Description:
//

package main

import (
	"bufio"
	"database/sql"
	"fmt"
	"log"
	"os"
	"strings"

	_ "github.com/mattn/go-sqlite3"
)

// global const & var
const dbFile = "example.db"
var db *sql.DB

// int database
func initDB() {
	var err error
	db, err = sql.Open("sqlite3", dbFile)
	if err != nil {
		log.Fatalf("Failed to open Database: %v", err)
	}

	// Create table if not exist
	createStmt := `
	CREATE TABLE IF NOT EXISTS items (
		id   INTEGER PRIMARY KEY AUTOINCREMENT,
		col1 TEXT NOT NULL,
		col2 TEXT NOT NULL,
		col3 TEXT NOT NULL
	);`
	_, err = db.Exec(createStmt)
	if err != nil {
		log.Fatalf("Creating table failed: %v", err)
	}
}

// insertItems
func insertItem() {
	reader := bufio.NewReader(os.Stdin)

	fmt.Print("\nText: ")
	first, _ := reader.ReadString('\n')
	first = strings.TrimSpace(first)

	fmt.Print("Text: ")
	second, _ := reader.ReadString('\n')
	second = strings.TrimSpace(second)

	fmt.Print("Date: ")
	date, _ := reader.ReadString('\n')
	date = strings.TrimSpace(date)

	stmt, err := db.Prepare("INSERT INTO items(col1, col2, col3) VALUES(?, ?, ?)")
	if err != nil {
		fmt.Printf("Prepare INSERT failed: %v\n", err)
		return
	}
	defer stmt.Close()

	_, err = stmt.Exec(first, second, date)
	if err != nil {
		fmt.Printf("Insert failed: %v\n", err)
		return
	}
	fmt.Println("Done")
}

// listItems read all columns of the table
func listItems() {
	rows, err := db.Query("SELECT id, col1, col2, col3 FROM items ORDER BY id")
	if err != nil {
		fmt.Printf("Query failed: %v\n", err)
		return
	}
	defer rows.Close()

	fmt.Println("\nOutput:")
	fmt.Println("ID | Col 1 | Col 2 | Col 3")
	fmt.Println("---+----------+----------+----------")

	var (
		id   int
		c1, c2, c3 string
	)
	hasRows := false
	for rows.Next() {
		hasRows = true
		if err := rows.Scan(&id, &c1, &c2, &c3); err != nil {
			fmt.Printf("failed to read rows: %v\n", err)
			return
		}
		fmt.Printf("%2d | %-8s | %-8s | %s\n", id, c1, c2, c3)
	}
	if !hasRows {
		fmt.Println("(table is empty)")
	}
}

// exit the program
func quit() {
	fmt.Println("\nhave a nice day")
	if db != nil {
		_ = db.Close()
	}
	os.Exit(0)
}

// draw the menu
func printMenu() {
	fmt.Println("\n=== Main ===")
	fmt.Println("1 – add entry")
	fmt.Println("2 – list entrys")
	fmt.Println("q – Exit")
	fmt.Print("Choose: ")
}

// Main‑Loop
func main() {
	initDB()
	defer db.Close()

	scanner := bufio.NewScanner(os.Stdin)

	for {
		printMenu()

		if !scanner.Scan() {
			// exit on errors
			break
		}
		choice := strings.TrimSpace(scanner.Text())

		switch choice {
		case "1":
			insertItem()
		case "2":
			listItems()
		case "q", "Q", "quit", "exit":
			quit()
		default:
			//fmt.Println("wrong input")
		}
	}
}