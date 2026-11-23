package rnnoise

import (
	"math"
	"math/rand"
	"testing"
)

func TestProcessFrameRejectsWrongSize(t *testing.T) {
	d, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	if _, err := d.ProcessFrame(make([]float32, FrameSize-1)); err == nil {
		t.Fatal("expected an error for a short frame")
	}
	if _, err := d.ProcessFrame(make([]float32, FrameSize+1)); err == nil {
		t.Fatal("expected an error for a long frame")
	}
}

func TestClosedDenoiser(t *testing.T) {
	d, err := New()
	if err != nil {
		t.Fatal(err)
	}
	d.Close()
	if _, err := d.ProcessFrame(make([]float32, FrameSize)); err == nil {
		t.Fatal("expected an error after Close")
	}
}

func TestProcessSilence(t *testing.T) {
	d, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	frame := make([]float32, FrameSize)
	// Warm the denoiser up; the first frames carry internal filter state.
	var vad float32
	for i := 0; i < 10; i++ {
		vad, err = d.ProcessFrame(frame)
		if err != nil {
			t.Fatal(err)
		}
	}
	for i, s := range frame {
		if math.IsNaN(float64(s)) || math.IsInf(float64(s), 0) {
			t.Fatalf("sample %d is not finite: %v", i, s)
		}
		if math.Abs(float64(s)) > 1 {
			t.Fatalf("sample %d out of range: %v", i, s)
		}
	}
	if vad > 0.5 {
		t.Fatalf("silence reported high voice activity: %v", vad)
	}
}

func TestProcessNoiseProducesFiniteOutput(t *testing.T) {
	d, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	rng := rand.New(rand.NewSource(1))
	frame := make([]float32, FrameSize)
	for i := range frame {
		frame[i] = float32(rng.Float64()*2-1) * 0.1
	}
	if _, err := d.ProcessFrame(frame); err != nil {
		t.Fatal(err)
	}
	for i, s := range frame {
		if math.IsNaN(float64(s)) || math.IsInf(float64(s), 0) {
			t.Fatalf("sample %d is not finite: %v", i, s)
		}
	}
}
