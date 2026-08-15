package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/vitorcds/music-tracker/internal/config"
	"github.com/vitorcds/music-tracker/internal/ui"
)

func main() {
	cfg, _ := config.LoadConfig()

	app := ui.NewAppModel(cfg)
	program := tea.NewProgram(app, tea.WithAltScreen())

	if _, err := program.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "erro ao iniciar TUI: %v\n", err)
	}
}
