package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/vitorcds/music-tracker/internal/config"
)

type ConfigSavedMsg struct {
	NewConfig config.AppConfig
}

type SettingsModel struct {
	inputs []textinput.Model
	focus  int
	cfg    config.AppConfig
	saved  bool
}

func NewSettingsModel(cfg config.AppConfig) SettingsModel {
	settingsModel := SettingsModel{
		inputs: make([]textinput.Model, 4),
		cfg:    cfg,
	}

	settingsModel.inputs[0] = textinput.New()
	settingsModel.inputs[0].Placeholder = "local para download"
	settingsModel.inputs[0].SetValue(cfg.DownloadPath)
	settingsModel.inputs[0].Focus()

	settingsModel.inputs[1] = textinput.New()
	settingsModel.inputs[1].Placeholder = "mp3, ogg, ..."
	settingsModel.inputs[1].SetValue(cfg.AudioFormat)

	settingsModel.inputs[2] = textinput.New()
	settingsModel.inputs[2].Placeholder = "low, high, very_high"
	settingsModel.inputs[2].SetValue(cfg.AudioQuality)

	settingsModel.inputs[3] = textinput.New()
	settingsModel.inputs[3].Placeholder = "spotify, youtube"
	settingsModel.inputs[3].SetValue(cfg.DownloadFrom)

	for i := range settingsModel.inputs {
		settingsModel.inputs[i].Cursor.SetMode(cursor.CursorStatic)
	}

	return settingsModel
}

func (model SettingsModel) Init() tea.Cmd {
	return nil
}

func (model SettingsModel) Update(msg tea.Msg) (SettingsModel, tea.Cmd) {
	var cmds []tea.Cmd

	if keyMsg, ok := msg.(tea.KeyMsg); ok {
		switch keyMsg.String() {
		case "up":
			model.saved = false
			if model.focus > 0 {
				model.focus--
			}
			return model, model.updateFocus()
		case "down":
			model.saved = false
			if model.focus < len(model.inputs)-1 {
				model.focus++
			}
			return model, model.updateFocus()
		case "ctrl+s":
			model.cfg.DownloadPath = model.inputs[0].Value()
			model.cfg.AudioFormat = model.inputs[1].Value()
			model.cfg.AudioQuality = model.inputs[2].Value()
			model.cfg.DownloadFrom = model.inputs[3].Value()

			err := config.SaveConfig(model.cfg)
			if err == nil {
				model.saved = true
				return model, func() tea.Msg {
					return ConfigSavedMsg{NewConfig: model.cfg}
				}
			}
		}
	}

	cmd := model.updateInputs(msg)
	cmds = append(cmds, cmd)

	return model, tea.Batch(cmds...)
}

func (model SettingsModel) View() string {
	var sb strings.Builder

	labels := []string{"caminho:", "formato:", "qualidade:", "player:"}

	for i := range model.inputs {
		fmt.Fprintf(&sb, "%-20s %s\n", labels[i], model.inputs[i].View())
	}

	sb.WriteString("\n[j/k] navegar | [ctrl+s] salvar")

	if model.saved {
		sb.WriteString("salvo")
	}

	return sb.String()
}

func (model *SettingsModel) updateFocus() tea.Cmd {
	var cmds []tea.Cmd
	for i := range model.inputs {
		if i == model.focus {
			cmds = append(cmds, model.inputs[i].Focus())
		} else {
			model.inputs[i].Blur()
		}
	}
	return tea.Batch(cmds...)
}

func (model *SettingsModel) updateInputs(msg tea.Msg) tea.Cmd {
	var cmds []tea.Cmd
	for i := range model.inputs {
		var cmd tea.Cmd
		model.inputs[i], cmd = model.inputs[i].Update(msg)
		cmds = append(cmds, cmd)
	}
	return tea.Batch(cmds...)
}
