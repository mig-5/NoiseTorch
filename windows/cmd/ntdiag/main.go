// Command ntdiag is a console diagnostic tool for the NoiseTorch Windows audio
// engine. It lists WASAPI endpoints and can run the RNNoise duplex pipeline for
// a bounded time, printing VAD/level statistics so the pipeline can be validated
// without interacting with the GUI.
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gen2brain/malgo"

	"noisetorch/windows/internal/audio"
	"noisetorch/windows/internal/rnnoise"
)

func main() {
	var (
		list     = flag.Bool("list", true, "list capture and playback devices")
		monitor  = flag.Duration("monitor", 0, "run the engine for this long (e.g. 10s) and print stats")
		capture  = flag.String("capture", "", "case-insensitive substring of the capture device name")
		playback = flag.String("playback", "", "case-insensitive substring of the playback device name")
		thresh   = flag.Int("threshold", 95, "voice activation threshold (0..95, 0 disables gating)")
	)
	flag.Parse()

	if err := run(*list, *monitor, *capture, *playback, *thresh); err != nil {
		fmt.Fprintln(os.Stderr, "ntdiag:", err)
		os.Exit(1)
	}
}

func run(list bool, monitor time.Duration, capture, playback string, threshold int) error {
	ctx, err := audio.NewContext()
	if err != nil {
		return fmt.Errorf("initialise WASAPI: %w", err)
	}
	defer func() {
		ctx.Uninit()
		ctx.Free()
	}()

	inputs, err := audio.List(ctx, malgo.Capture)
	if err != nil {
		return fmt.Errorf("enumerate capture devices: %w", err)
	}
	outputs, err := audio.List(ctx, malgo.Playback)
	if err != nil {
		return fmt.Errorf("enumerate playback devices: %w", err)
	}

	if list {
		fmt.Println("Capture devices:")
		for i, d := range inputs {
			fmt.Printf("  [%d] %s%s\n", i, d.Name, defaultMark(d.IsDefault))
		}
		fmt.Println("Playback devices:")
		for i, d := range outputs {
			fmt.Printf("  [%d] %s%s\n", i, d.Name, defaultMark(d.IsDefault))
		}
		fmt.Printf("Virtual microphone present: %t\n", hasVirtual(outputs))
	}

	if monitor <= 0 {
		return nil
	}

	in, ok := pick(inputs, capture)
	if !ok {
		return fmt.Errorf("no capture device matches %q", capture)
	}
	out, ok := pick(outputs, playback)
	if !ok {
		return fmt.Errorf("no playback device matches %q", playback)
	}

	den, err := rnnoise.New()
	if err != nil {
		return fmt.Errorf("initialise RNNoise: %w", err)
	}
	defer den.Close()

	engine := audio.NewEngine(ctx, den, threshold)
	if err := engine.Start(in.ID, out.ID); err != nil {
		return fmt.Errorf("start stream %q -> %q: %w", in.Name, out.Name, err)
	}
	defer engine.Stop()

	fmt.Printf("Streaming %q -> %q for %s (threshold %d)\n", in.Name, out.Name, monitor, threshold)

	deadline := time.Now().Add(monitor)
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	for now := range tick.C {
		vad, open := engine.LastStats()
		state := "muted"
		if open {
			state = "passing"
		}
		fmt.Printf("%6.1fs  level=%5.1f%%  vad=%5.1f%%  gate=%s\n",
			monitor.Seconds()-deadline.Sub(now).Seconds(),
			engine.LastLevel()*100, vad*100, state)
		if !now.Before(deadline) {
			break
		}
	}
	return nil
}

func defaultMark(isDefault bool) string {
	if isDefault {
		return "  (default)"
	}
	return ""
}

func hasVirtual(devs []audio.Device) bool {
	for _, d := range devs {
		n := strings.ToLower(d.Name)
		if strings.Contains(n, "noisetorch virtual") || strings.Contains(n, "nt-vad") {
			return true
		}
	}
	return false
}

// pick resolves a device by case-insensitive name substring, falling back to the
// system default when no filter is supplied.
func pick(devs []audio.Device, filter string) (audio.Device, bool) {
	if filter != "" {
		f := strings.ToLower(filter)
		for _, d := range devs {
			if strings.Contains(strings.ToLower(d.Name), f) {
				return d, true
			}
		}
		return audio.Device{}, false
	}
	for _, d := range devs {
		if d.IsDefault {
			return d, true
		}
	}
	if len(devs) > 0 {
		return devs[0], true
	}
	return audio.Device{}, false
}
