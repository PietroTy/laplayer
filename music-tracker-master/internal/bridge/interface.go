package bridge

import (
	"errors"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/vitorcds/music-tracker/internal/config"
)

type MsgToPython struct {
	Action       string   `json:"action"`
	Url          string   `json:"url,omitempty"`
	PlaylistName string   `json:"playlistName,omitempty"`
	Ids          []string `json:"ids,omitempty"`
	Quality      string   `json:"quality,omitempty"`
	DownloadPath string   `json:"downloadPath,omitempty"`
}

type MsgFromPython struct {
	Event        string `json:"event"`
	Message      string `json:"message"`
	PlaylistName string `json:"playlistName"`
}

type Provider interface {
	StartWorker(channel chan MsgFromPython) error
	SendCommand(msg MsgToPython) error

	Auth() error
	Scrap(url string, config config.AppConfig) tea.Cmd
	Download(playlistName string, ids []string, cfg config.AppConfig) tea.Cmd
}

func ListenForEvents(sub chan MsgFromPython) tea.Cmd {
	return func() tea.Msg {
		if line, ok := <-sub; ok {
			return line
		}

		return nil
	}
}

func ListenForLines(sub chan string) tea.Cmd {
	return func() tea.Msg {
		if line, ok := <-sub; ok {
			return LineMsg(line)
		}

		return nil
	}
}

func HasCredentials() bool {
	if _, err := os.Stat("credentials.json"); err == nil {
		return true
	} else if errors.Is(err, os.ErrNotExist) {
		return false
	}

	return false
}
