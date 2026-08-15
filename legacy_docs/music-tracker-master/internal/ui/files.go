package ui

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

type FilesModel struct {
	defaultPath string
	path        string
	files       []os.DirEntry
	cursor      int
	err         error
}

func NewFilesModel(downloadsPath string) FilesModel {
	model := FilesModel{
		defaultPath: downloadsPath,
		path:        downloadsPath,
	}
	return model.Reload()
}

func (model FilesModel) Init() tea.Cmd {
	return nil
}

func (model FilesModel) Update(msg tea.Msg) (FilesModel, tea.Cmd) {
	if keyMsg, ok := msg.(tea.KeyMsg); ok {
		switch keyMsg.String() {
		case "up":
			if model.cursor > 0 {
				model.cursor--
			}
		case "down":
			if model.cursor < len(model.files)-1 {
				model.cursor++
			}

		case "enter":
			currentFile := model.files[model.cursor]
			if currentFile.IsDir() {
				model.path = filepath.Join(model.path, currentFile.Name())
				model.cursor = 0
				model = model.Reload()
			}
		case "backspace":
			if model.path != model.defaultPath {
				model.path = filepath.Dir(model.path)
				model.cursor = 0
				model = model.Reload()
			}
		}

	}
	return model, nil
}

func (model FilesModel) View() string {
	var sb strings.Builder

	if model.err != nil {
		fmt.Fprintf(&sb, "erro ao ler pasta %s: \n%v\n", model.path, model.err)
		return sb.String()
	}

	sb.WriteString(model.path)
	sb.WriteString("\n")

	if len(model.files) == 0 {
		sb.WriteString("nenhum arquivo encontrado\n")
		return sb.String()
	}

	start := 0
	end := len(model.files)
	maxItems := 12

	if len(model.files) > maxItems {
		start = model.cursor - (maxItems / 2)
		start = max(start, 0)

		end = start + maxItems
		if end > len(model.files) {
			end = len(model.files)
			start = end - maxItems
		}
	}

	for i := start; i < end; i++ {
		file := model.files[i]
		cursorStr := " "
		if i == model.cursor {
			cursorStr = "> "
		}

		suffix := ""
		if file.IsDir() {
			suffix = "/"
		}

		fmt.Fprintf(&sb, "%s%s%s\n", cursorStr, file.Name(), suffix)
	}

	sb.WriteString("\n[j/k] navegar")

	return sb.String()
}

func (model FilesModel) Reload() FilesModel {
	entries, err := os.ReadDir(model.path)
	if err != nil {
		model.err = err
		return model
	}

	model.err = nil
	model.files = entries

	if model.cursor >= len(model.files) {
		model.cursor = len(model.files) - 1
	}

	if model.cursor < 0 {
		model.cursor = 0
	}

	return model
}
