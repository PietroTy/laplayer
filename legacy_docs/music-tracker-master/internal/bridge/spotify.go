package bridge

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/dhowden/tag"
	"github.com/vitorcds/music-tracker/internal/config"
)

type SpotifyProvider struct {
	workerStdin io.Writer
}

type LineMsg string
type AuthDoneMsg struct {
	Err error
}
type ScrapDoneMsg struct {
	PlaylistName string
	DownloadIds  []string
	Err          error
}
type DownloadDoneMsg struct {
	Err error
}

func (sp *SpotifyProvider) StartWorker(channel chan MsgFromPython) error {
	cmd := exec.Command("python3", "-u", "../../internal/scripts/worker.py")

	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	sp.workerStdin = stdinPipe

	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}

	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return err
	}

	if err := cmd.Start(); err != nil {
		return err
	}

	go func() {
		scanner := bufio.NewScanner(stdoutPipe)
		if err := scanner.Err(); err != nil {
			channel <- MsgFromPython{Event: "log", Message: "erro no scanner"}
		}

		for scanner.Scan() {
			line := scanner.Text()

			var msg MsgFromPython
			err := json.Unmarshal([]byte(line), &msg)

			if err == nil {
				channel <- msg
			} else {
				channel <- MsgFromPython{Event: "log", Message: line}
			}
		}
	}()

	go func() {
		scanner := bufio.NewScanner(stderrPipe)
		if err := scanner.Err(); err != nil {
			channel <- MsgFromPython{Event: "log", Message: "erro no scanner de erro"}
		}

		for scanner.Scan() {
			line := scanner.Text()
			channel <- MsgFromPython{Event: "error", Message: line}
		}
	}()

	return nil
}

func (sp *SpotifyProvider) SendCommand(msg MsgToPython) error {
	jsonMsg, err := json.Marshal(msg)
	if err != nil {
		return err
	}

	jsonMsg = append(jsonMsg, '\n')
	_, err = sp.workerStdin.Write(jsonMsg)
	if err != nil {
		return err
	}
	return nil
}

func (sp SpotifyProvider) Auth() error {
	authMsg := MsgToPython{
		Action: "login",
	}

	err := sp.SendCommand(authMsg)
	if err != nil {
		return err
	}

	return nil
}

func (sp SpotifyProvider) ScrapOnline(url string) (string, []string, error) {
	cmd := exec.Command(
		"python3", "-u", "../../internal/scripts/scraper.py",
		"credentials.json", url,
	)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", nil, err
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return "", nil, err
	}

	if err := cmd.Start(); err != nil {
		return "", nil, err
	}

	multi := io.MultiReader(stdout, stderr)
	scanner := bufio.NewScanner(multi)

	var jsonRaw strings.Builder
	recordingJson := false

	for scanner.Scan() {
		line := scanner.Text()

		if strings.TrimSpace(line) == "" {
			continue
		}

		if line == "json" {
			recordingJson = true
			continue
		}

		if recordingJson {
			jsonRaw.WriteString(line)
		}
	}
	if err := scanner.Err(); err != nil {
	}

	type ScaperReturn struct {
		PlaylistName string `json:"playlist"`
		ID           string `json:"spotify_id"`
	}

	var items []ScaperReturn

	err = json.Unmarshal([]byte(jsonRaw.String()), &items)
	if err != nil {
		return "", nil, err
	}

	var playlistName string
	var musicIds []string
	for _, item := range items {
		if item.PlaylistName != "" {
			playlistName = item.PlaylistName
		}

		if item.ID != "" {
			musicIds = append(musicIds, item.ID)
		}
	}

	err = cmd.Wait()
	if err != nil {
	}

	return playlistName, musicIds, nil
}

func (sp SpotifyProvider) ScrapLocal(musicsPath string, musicFormat string) ([]string, error) { // maybe turn into global to all providers
	var localIds []string

	entries, err := os.ReadDir(musicsPath)
	if err != nil {
		return nil, err
	}

	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != musicFormat {
			continue
		}

		fullPath := filepath.Join(musicsPath, entry.Name())
		file, err := os.Open(fullPath)
		if err != nil {
			continue
		}

		metadata, err := tag.ReadFrom(file)
		file.Close()
		if err != nil {
			continue
		}

		rawTags := metadata.Raw()
		if value, exists := rawTags["spotify_id"]; exists {
			if spotifyIdStr, ok := value.(string); ok {
				localIds = append(localIds, strings.TrimSpace(spotifyIdStr))
			}
		}
	}

	return localIds, nil
}

func (sp SpotifyProvider) Scrap(url string, config config.AppConfig) tea.Cmd {
	return func() tea.Msg {
		playlistName, onlineIds, err := sp.ScrapOnline(url)
		if err != nil {
			return ScrapDoneMsg{Err: err}
		}
		if len(onlineIds) <= 0 {
			emptyError := errors.New("any id found")
			return ScrapDoneMsg{Err: emptyError}
		}

		downloadedPath := filepath.Join(config.DownloadPath, playlistName)

		localIds, errLocal := sp.ScrapLocal(downloadedPath, config.AudioFormat)
		if errLocal != nil {
			if os.IsNotExist(errLocal) {
				return ScrapDoneMsg{PlaylistName: playlistName, DownloadIds: onlineIds}
			}
			return ScrapDoneMsg{Err: errLocal}
		}
		if len(localIds) == 0 {
			return ScrapDoneMsg{PlaylistName: playlistName, DownloadIds: onlineIds}
		}

		return nil
	}
}

func (sp SpotifyProvider) Download(playlistName string, ids []string, cfg config.AppConfig) tea.Cmd {
	return func() tea.Msg {

		cmd := exec.Command(
			"python3", "-u", "../../internal/scripts/downloader.py",
			"credentials.json", cfg.DownloadPath, cfg.AudioQuality, playlistName,
		)

		idsUnified := strings.Join(ids, "\n")
		cmd.Stdin = strings.NewReader(idsUnified)

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			return DownloadDoneMsg{Err: err}
		}

		stderr, err := cmd.StderrPipe()
		if err != nil {
			return DownloadDoneMsg{Err: err}
		}

		if err := cmd.Start(); err != nil {
			return DownloadDoneMsg{Err: err}
		}

		multi := io.MultiReader(stdout, stderr)
		scanner := bufio.NewScanner(multi)

		for scanner.Scan() {
			line := scanner.Text()

			if line != "" {
			}
		}

		if err := scanner.Err(); err != nil {
		}
		err = cmd.Wait()
		if err != nil {
		}

		return DownloadDoneMsg{Err: err}
	}
}
