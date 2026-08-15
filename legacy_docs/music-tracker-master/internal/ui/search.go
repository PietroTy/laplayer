package ui

import (
	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

type SearchModel struct {
	TextInput textinput.Model
}

func NewSearchModel() SearchModel {
	ti := textinput.New()
	ti.Placeholder = "url a ser baixado (link da música no spotify)"
	ti.CharLimit = 200
	ti.Width = 100

	ti.Cursor.SetMode(cursor.CursorStatic)
	ti.Focus()

	return SearchModel{TextInput: ti}
}

func (model SearchModel) Init() tea.Cmd {
	return nil
}

func (model SearchModel) Update(msg tea.Msg) (SearchModel, tea.Cmd) {
	var cmd tea.Cmd
	model.TextInput, cmd = model.TextInput.Update(msg)
	return model, cmd
}

func (model SearchModel) View() string {
	return "buscar música \n" + model.TextInput.View() + "\n\n" +
		"[enter] buscar | [ctrl+c] sair"
}
