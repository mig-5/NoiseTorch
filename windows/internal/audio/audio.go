// Package audio implements the Windows WASAPI audio engine for NoiseTorch.
//
// It opens a full-duplex stream: the selected physical microphone is captured,
// denoised by RNNoise and played back into the "NoiseTorch Virtual Microphone"
// render endpoint exposed by the companion NT-VAD kernel driver. That driver
// loops the render stream into its capture endpoint, which applications then
// see as a regular recording device.
package audio

import (
	"errors"
	"math"
	"sync"
	"unsafe"

	"github.com/gen2brain/malgo"
	"noisetorch/windows/internal/rnnoise"
)

// Device is a user-facing audio endpoint.
type Device struct {
	ID        malgo.DeviceID
	Name      string
	IsDefault bool
}

// NewContext initialises a miniaudio context. Call Free when done.
func NewContext() (*malgo.AllocatedContext, error) {
	return malgo.InitContext(nil, malgo.ContextConfig{}, func(string) {})
}

// List returns the available endpoints for the given kind (Capture or Playback).
func List(ctx *malgo.AllocatedContext, kind malgo.DeviceType) ([]Device, error) {
	infos, err := ctx.Devices(kind)
	if err != nil {
		return nil, err
	}
	out := make([]Device, 0, len(infos))
	for i := range infos {
		out = append(out, Device{
			ID:        infos[i].ID,
			Name:      infos[i].Name(),
			IsDefault: infos[i].IsDefault != 0,
		})
	}
	return out, nil
}

// vadGraceFrames mirrors VAD_GRACE_PERIOD from c/ladspa/module.c: after a frame
// is classified as speech, keep passing audio for this many frames (20 * 20 ms
// = 400 ms) so word tails are not clipped.
const vadGraceFrames = 20

// Engine owns the duplex stream and the RNNoise processing pipeline.
type Engine struct {
	ctx  *malgo.AllocatedContext
	den  *rnnoise.Denoiser
	dev  *malgo.Device
	ids  []unsafe.Pointer // keeps ID allocations alive for the stream lifetime
	fbuf []float32        // scratch for one callback

	mu        sync.Mutex
	pending   []float32 // captured samples not yet forming a full RNNoise frame
	ready     []float32 // denoised samples queued for playback
	threshold int       // 0..95 voice activation threshold (0 disables gating)
	vad       float32   // last voice activity probability
	level     float32   // last captured input RMS (0..1)
	grace     int       // remaining grace frames
	open      bool      // last frame was passed through (after grace)
}

// NewEngine creates an engine bound to an existing miniaudio context.
func NewEngine(ctx *malgo.AllocatedContext, den *rnnoise.Denoiser, threshold int) *Engine {
	if threshold < 0 {
		threshold = 0
	}
	if threshold > 95 {
		// Upstream NoiseTorch caps the voice activation threshold at 95%.
		threshold = 95
	}
	e := &Engine{ctx: ctx, den: den, threshold: threshold, grace: vadGraceFrames}
	// Prefill one frame of silence so the delayed RNNoise output never
	// underruns on the very first callback.
	e.ready = make([]float32, rnnoise.FrameSize)
	return e
}

// SetThreshold updates the voice activation threshold (0..95; 0 disables gating).
func (e *Engine) SetThreshold(t int) {
	if t < 0 {
		t = 0
	}
	if t > 95 {
		t = 95
	}
	e.mu.Lock()
	e.threshold = t
	e.mu.Unlock()
}

// LastVAD returns the most recent voice activity probability (0..1).
func (e *Engine) LastVAD() float32 {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.vad
}

// LastStats returns the most recent VAD probability and whether the most recent
// frame was passed to the output (after the grace period).
func (e *Engine) LastStats() (vad float32, open bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.vad, e.open
}

// LastLevel returns the RMS level of the most recently captured callback
// (0..1), useful for diagnostics.
func (e *Engine) LastLevel() float32 {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.level
}

// Start opens the duplex stream between the physical capture device and the
// virtual playback endpoint.
func (e *Engine) Start(captureID, playbackID malgo.DeviceID) error {
	if e.dev != nil {
		return errors.New("audio: engine already started")
	}

	cfg := malgo.DefaultDeviceConfig(malgo.Duplex)
	cfg.Capture.Format = malgo.FormatF32
	cfg.Capture.Channels = 1
	cfg.Capture.DeviceID = captureID.Pointer()
	cfg.Capture.ShareMode = malgo.Shared

	cfg.Playback.Format = malgo.FormatF32
	cfg.Playback.Channels = 1
	cfg.Playback.DeviceID = playbackID.Pointer()
	cfg.Playback.ShareMode = malgo.Shared

	cfg.SampleRate = rnnoise.SampleRate
	cfg.PeriodSizeInMilliseconds = 20
	cfg.PerformanceProfile = malgo.LowLatency

	e.ids = append(e.ids, cfg.Capture.DeviceID, cfg.Playback.DeviceID)

	dev, err := malgo.InitDevice(e.ctx.Context, cfg, malgo.DeviceCallbacks{Data: e.onData})
	if err != nil {
		return err
	}
	if err := dev.Start(); err != nil {
		dev.Uninit()
		return err
	}
	e.dev = dev
	return nil
}

// Stop closes the stream. Safe to call multiple times.
func (e *Engine) Stop() {
	if e.dev != nil {
		_ = e.dev.Stop()
		e.dev.Uninit()
		e.dev = nil
	}
}

// onData runs on a realtime miniaudio thread. In duplex mode both buffers are
// valid and hold mono interleaved float32 PCM.
func (e *Engine) onData(out, in []byte, frames uint32) {
	n := int(frames)
	if n == 0 {
		return
	}
	if cap(e.fbuf) < n {
		e.fbuf = make([]float32, n)
	}
	buf := e.fbuf[:n]

	// Duplex requires both directions to be sized for n mono float frames.
	if len(in) < n*4 || len(out) < n*4 {
		for i := range out {
			out[i] = 0
		}
		return
	}
	src := unsafe.Slice((*float32)(unsafe.Pointer(&in[0])), n)
	copy(buf, src)

	var acc float64
	for _, s := range buf {
		acc += float64(s) * float64(s)
	}
	rms := float32(math.Sqrt(acc / float64(len(buf))))

	e.mu.Lock()
	e.level = rms
	// Process any complete 480-sample frames.
	e.pending = append(e.pending, buf...)
	for len(e.pending) >= rnnoise.FrameSize {
		frame := e.pending[:rnnoise.FrameSize]
		vad, err := e.den.ProcessFrame(frame)
		e.pending = e.pending[rnnoise.FrameSize:]
		if err != nil {
			continue
		}
		e.vad = vad

		// Mirror c/ladspa/module.c: a frame above the threshold opens the gate
		// for VAD_GRACE_PERIOD frames; otherwise the gate closes and the frame
		// is muted. A threshold of 0 disables gating entirely.
		pass := true
		if e.threshold > 0 {
			if vad*100 > float32(e.threshold) {
				e.grace = vadGraceFrames
			}
			if e.grace >= 0 {
				e.grace--
			} else {
				pass = false
			}
		}
		if !pass {
			for i := range frame {
				frame[i] = 0
			}
		}
		e.open = pass
		e.ready = append(e.ready, frame...)
	}

	// Serve exactly n samples to the render endpoint.
	dst := unsafe.Slice((*float32)(unsafe.Pointer(&out[0])), n)
	have := len(e.ready)
	if have >= n {
		copy(dst, e.ready[:n])
		e.ready = e.ready[n:]
	} else {
		copy(dst, e.ready)
		for i := have; i < n; i++ {
			dst[i] = 0
		}
		e.ready = e.ready[:0]
	}
	// Bound the queues to keep latency from drifting if the clocks differ.
	if len(e.pending) > rnnoise.FrameSize*4 {
		e.pending = e.pending[len(e.pending)-rnnoise.FrameSize*4:]
	}
	if len(e.ready) > rnnoise.FrameSize*4 {
		e.ready = e.ready[len(e.ready)-rnnoise.FrameSize*4:]
	}
	e.mu.Unlock()
}
