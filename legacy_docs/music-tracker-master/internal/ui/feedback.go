package ui

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/vitorcds/music-tracker/internal/bridge"
)

type FeedbackModel struct {
	lastMessage string
}

func NewFeedbackModel() FeedbackModel {
	return FeedbackModel{lastMessage: "aguardando conexao com worker..."}
}

func (m FeedbackModel) Update(msg tea.Msg) (FeedbackModel, tea.Cmd) {
	switch msg := msg.(type) {
	case bridge.MsgFromPython:
		if msg.Message != "" {
			m.lastMessage = msg.Message
		}
	}
	return m, nil
}

func (m FeedbackModel) View() string {
	var sb strings.Builder
	sb.WriteString(">> ")
	sb.WriteString(m.lastMessage)
	return sb.String()
}
