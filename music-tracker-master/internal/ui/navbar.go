package ui

import (
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

type NavbarModel struct {
	Tabs []string
}

func NewNavbarModel() NavbarModel {
	return NavbarModel{Tabs: []string{"busca", "arquivos", "config"}}
}

func (model NavbarModel) Init() tea.Cmd {
	return textinput.Blink
}

func (model NavbarModel) Update(msg tea.Msg) (NavbarModel, tea.Cmd) {
	var cmd tea.Cmd
	return model, cmd
}

func (model NavbarModel) View(activeTab int) string {
	var sb strings.Builder

	sb.WriteString("[H]  ")

	for i, tab := range model.Tabs {
		if i == activeTab {
			sb.WriteString("[ ")
			sb.WriteString(tab)
			sb.WriteString(" ]")
		} else {
			sb.WriteString(" ")
			sb.WriteString(tab)
			sb.WriteString(" ")
		}
	}

	sb.WriteString("  [L]")

	return sb.String()
}
