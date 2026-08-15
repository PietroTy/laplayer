package ui

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/vitorcds/music-tracker/internal/bridge"
)

type DownloadModel struct {
	lines []string
	done  bool
	err   error
}

func NewDownloadModel() DownloadModel {
	return DownloadModel{
		lines: []string{},
	}
}

func (model DownloadModel) Update(msg tea.Msg) (DownloadModel, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case bridge.LineMsg:
		model.lines = append(model.lines, string(msg))

		if len(model.lines) > 20 {
			model.lines = model.lines[len(model.lines)-20:]
		}

	case bridge.DownloadDoneMsg:
		model.err = msg.Err
		model.done = true
	}

	return model, tea.Batch(cmds...)
}

func (model DownloadModel) View() string {
	var sb strings.Builder

	sb.WriteString("\n")

	start := 0
	maxLines := 5

	if len(model.lines) > maxLines {
		start = len(model.lines) - maxLines
	}
	for _, line := range model.lines[start:] {
		sb.WriteString(" ")
		sb.WriteString(line)
		sb.WriteString("\n")
	}

	if model.done {
		if model.err != nil {
			return "erro ao baixar: " + sb.String() + "\n\nenter para voltar"
		}
		return "finalizado: \n" + sb.String()

	}

	return "baixando: \n\n" + sb.String() + "\n"
}
