// Package rnnoise is a thin cgo binding over the vendored Xiph RNNoise library
// (c/rnnoise) used by the Windows port of NoiseTorch.
package rnnoise

/*
#cgo CFLAGS: -I${SRCDIR}/../../../c/rnnoise/include -I${SRCDIR}/../../../c/rnnoise/src -O2 -std=gnu99 -D_GNU_SOURCE
#cgo windows LDFLAGS: -lm
#cgo linux LDFLAGS: -lm
#include <stdlib.h>
#include "rnnoise.h"

// ctx_new / ctx_free wrap the opaque DenoiseState so Go never touches C
// internals directly.
static DenoiseState *ctx_new(void) { return rnnoise_create(NULL); }
static void ctx_free(DenoiseState *st) { rnnoise_destroy(st); }
*/
import "C"

import (
	"errors"
	"sync"
	"unsafe"
)

// FrameSize is the fixed number of mono float samples RNNoise processes per call
// at 48 kHz (20 ms).
const FrameSize = 480

// SampleRate is the only sample rate RNNoise supports natively.
const SampleRate = 48000

// Denoiser is a single RNNoise processing context. It is safe for concurrent use.
type Denoiser struct {
	mu  sync.Mutex
	st  *C.DenoiseState
	buf [FrameSize]float32 // scratch conversion buffer
}

// New allocates a new RNNoise denoiser.
func New() (*Denoiser, error) {
	st := C.ctx_new()
	if st == nil {
		return nil, errors.New("rnnoise: could not allocate DenoiseState")
	}
	return &Denoiser{st: st}, nil
}

// Close releases the underlying RNNoise state.
func (d *Denoiser) Close() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.st != nil {
		C.ctx_free(d.st)
		d.st = nil
	}
}

// ProcessFrame denoises exactly FrameSize float32 samples in place. samples must
// have length FrameSize. The returned value is the estimated voice activity
// probability (0..1).
func (d *Denoiser) ProcessFrame(samples []float32) (float32, error) {
	if len(samples) != FrameSize {
		return 0, errors.New("rnnoise: process frame requires exactly 480 samples")
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.st == nil {
		return 0, errors.New("rnnoise: denoiser is closed")
	}

	// RNNoise works on 16-bit-range float PCM; use the same 32767 scale as the
	// upstream NoiseTorch LADSPA module so levels match the Linux build.
	for i := 0; i < FrameSize; i++ {
		d.buf[i] = samples[i] * 32767.0
	}

	vad := C.rnnoise_process_frame(
		d.st,
		(*C.float)(unsafe.Pointer(&d.buf[0])),
		(*C.float)(unsafe.Pointer(&d.buf[0])),
	)

	for i := 0; i < FrameSize; i++ {
		samples[i] = d.buf[i] / 32767.0
	}
	return float32(vad), nil
}
