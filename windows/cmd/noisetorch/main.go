// NoiseTorch for Windows: a native WASAPI + RNNoise front-end that feeds the
// NoiseTorch Virtual Microphone (NT-VAD) kernel driver.
package main

import (
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/gen2brain/malgo"
	"github.com/lxn/walk"
	. "github.com/lxn/walk/declarative"

	"noisetorch/windows/internal/audio"
	"noisetorch/windows/internal/rnnoise"
)

const appVersion = "0.1.0-windows"

type app struct {
	mw        *walk.MainWindow
	inputBox  *walk.ComboBox
	outputBox *walk.ComboBox
	slider    *walk.Slider
	status    *walk.Label
	logView   *walk.TextEdit
	startBtn  *walk.PushButton
	stopBtn   *walk.PushButton

	ctx    *malgo.AllocatedContext
	den    *rnnoise.Denoiser
	engine *audio.Engine

	inputs  []audio.Device
	outputs []audio.Device
}

func main() {
	a := &app{}

	var err error
	a.ctx, err = audio.NewContext()
	if err != nil {
		walk.MsgBox(nil, "NoiseTorch", "Could not initialise WASAPI: "+err.Error(), walk.MsgBoxIconError)
		os.Exit(1)
	}
	defer func() {
		a.ctx.Uninit()
		a.ctx.Free()
	}()

	a.den, err = rnnoise.New()
	if err != nil {
		walk.MsgBox(nil, "NoiseTorch", "Could not initialise RNNoise: "+err.Error(), walk.MsgBoxIconError)
		os.Exit(1)
	}
	defer a.den.Close()

	if err := a.build(); err != nil {
		log.Fatal(err)
	}

	a.refreshDevices()

	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	go func() {
		for range ticker.C {
			a.updateStatus()
		}
	}()

	a.mw.Run()
	a.shutdown()
}

func (a *app) build() error {
	return MainWindow{
		AssignTo: &a.mw,
		Title:    "NoiseTorch for Windows",
		Size:     Size{Width: 620, Height: 480},
		Layout:   VBox{},
		Children: []Widget{
			Composite{
				Layout: Grid{Columns: 2},
				Children: []Widget{
					Label{Text: "Microphone:"},
					ComboBox{
						AssignTo:              &a.inputBox,
						Editable:              false,
						OnCurrentIndexChanged: func() { a.updateStatus() },
					},
					Label{Text: "Virtual microphone (output):"},
					ComboBox{
						AssignTo: &a.outputBox,
						Editable: false,
					},
				},
			},
			Label{Text: "Voice activation threshold (higher = only speech passes):"},
			Slider{
				AssignTo:      &a.slider,
				MinValue:      0,
				MaxValue:      100,
				Value:         95,
				OnValueChanged: func() { a.onThreshold() },
			},
			Composite{
				Layout: HBox{},
				Children: []Widget{
					PushButton{
						AssignTo:  &a.startBtn,
						Text:      "Start",
						OnClicked: func() { a.start() },
					},
					PushButton{
						AssignTo:  &a.stopBtn,
						Text:      "Stop",
						OnClicked: func() { a.stop() },
					},
					PushButton{
						Text:      "Refresh devices",
						OnClicked: func() { a.refreshDevices() },
					},
				},
			},
			Label{AssignTo: &a.status, Text: "Idle"},
			TextEdit{
				AssignTo: &a.logView,
				ReadOnly: true,
				VScroll:  true,
			},
		},
	}.Create()
}

func (a *app) refreshDevices() {
	inputs, err := audio.List(a.ctx, malgo.Capture)
	if err != nil {
		a.logf("Could not enumerate capture devices: %v", err)
		return
	}
	outputs, err := audio.List(a.ctx, malgo.Playback)
	if err != nil {
		a.logf("Could not enumerate playback devices: %v", err)
		return
	}
	a.inputs, a.outputs = inputs, outputs

	inNames := make([]string, len(inputs))
	for i, d := range inputs {
		inNames[i] = d.Name
	}
	outNames := make([]string, len(outputs))
	virtualIdx := -1
	for i, d := range outputs {
		outNames[i] = d.Name
		if isVirtualDevice(d.Name) && virtualIdx == -1 {
			virtualIdx = i
		}
	}

	a.inputBox.SetModel(inNames)
	a.outputBox.SetModel(outNames)
	if len(inNames) > 0 {
		a.inputBox.SetCurrentIndex(0)
	}
	if virtualIdx >= 0 {
		a.outputBox.SetCurrentIndex(virtualIdx)
	} else if len(outNames) > 0 {
		a.outputBox.SetCurrentIndex(0)
		a.logf("No NoiseTorch virtual device found. Install the NT-VAD driver or pick another output for monitoring.")
	}
	a.logf("Found %d capture and %d playback devices.", len(inputs), len(outputs))
}

func (a *app) onThreshold() {
	if a.engine != nil {
		a.engine.SetThreshold(a.slider.Value())
	}
}

func (a *app) start() {
	if a.engine != nil {
		return
	}
	ii := a.inputBox.CurrentIndex()
	oi := a.outputBox.CurrentIndex()
	if ii < 0 || ii >= len(a.inputs) || oi < 0 || oi >= len(a.outputs) {
		walk.MsgBox(a.mw, "NoiseTorch", "Select a microphone and a virtual output device first.", walk.MsgBoxIconWarning)
		return
	}

	a.engine = audio.NewEngine(a.ctx, a.den, a.slider.Value())
	if err := a.engine.Start(a.inputs[ii].ID, a.outputs[oi].ID); err != nil {
		a.engine = nil
		walk.MsgBox(a.mw, "NoiseTorch", "Could not start the audio stream: "+err.Error(), walk.MsgBoxIconError)
		return
	}
	a.startBtn.SetEnabled(false)
	a.stopBtn.SetEnabled(true)
	a.logf("Streaming %q -> %q", a.inputs[ii].Name, a.outputs[oi].Name)
}

func (a *app) stop() {
	if a.engine == nil {
		return
	}
	a.engine.Stop()
	a.engine = nil
	a.startBtn.SetEnabled(true)
	a.stopBtn.SetEnabled(false)
	a.logf("Stopped.")
}

func (a *app) updateStatus() {
	if a.mw == nil {
		return
	}
	a.mw.Synchronize(func() {
		if a.engine == nil {
			a.status.SetText("Idle")
			return
		}
		vad := a.engine.LastVAD() * 100
		state := "muted"
		if vad >= float32(a.slider.Value()) {
			state = "passing"
		}
		a.status.SetText(fmt.Sprintf("Running - voice activity %.0f%% (%s)", vad, state))
	})
}

func (a *app) logf(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	if a.logView == nil {
		return
	}
	a.logView.AppendText(msg + "\r\n")
}

func (a *app) shutdown() {
	a.stop()
}

func isVirtualDevice(name string) bool {
	// The NT-VAD driver publishes endpoints under this name (see windows/driver).
	name = strings.ToLower(name)
	for _, marker := range []string{"noisetorch virtual", "nt-vad"} {
		if strings.Contains(name, marker) {
			return true
		}
	}
	return false
}
