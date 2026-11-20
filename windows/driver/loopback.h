/*
 * NoiseTorch Virtual Audio Device (NT-VAD)
 *
 * Lock-free single-producer / single-consumer ring buffer shared between the
 * render path (audio played INTO the virtual cable by the NoiseTorch engine)
 * and the capture path (audio read OUT of it by conferencing apps).
 *
 * Copyright (c) 2026 NoiseTorch-Windows contributors. GPL-3.0.
 */
#pragma once

#include <ntddk.h>
#include <stdint.h>

#define NTVAD_RING_FRAMES 16384u /* ~341 ms at 48 kHz mono */
#define NTVAD_RING_MASK (NTVAD_RING_FRAMES - 1u)

typedef struct _NTVAD_LOOPBACK {
    /* Mono float32 samples. */
    float    buffer[NTVAD_RING_FRAMES];
    volatile LONG64 writePos; /* advanced by render */
    volatile LONG64 readPos;  /* advanced by capture */
    KSPIN_LOCK lock;
} NTVAD_LOOPBACK, *PNTVAD_LOOPBACK;

static __inline void NTVadLoopbackInit(_Out_ PNTVAD_LOOPBACK lb)
{
    RtlZeroMemory(lb, sizeof(*lb));
    KeInitializeSpinLock(&lb->lock);
}

static __inline void NTVadLoopbackReset(_Inout_ PNTVAD_LOOPBACK lb)
{
    KIRQL old;
    KeAcquireSpinLock(&lb->lock, &old);
    InterlockedExchange64(&lb->writePos, 0);
    InterlockedExchange64(&lb->readPos, 0);
    KeReleaseSpinLock(&lb->lock, old);
}

/* Render side: push n mono float samples. Drops the oldest data on overflow. */
static __inline void NTVadLoopbackWrite(
    _Inout_ PNTVAD_LOOPBACK lb,
    _In_reads_(n) const float *samples,
    _In_ size_t n)
{
    LONG64 w = InterlockedCompareExchange64(&lb->writePos, 0, 0);
    LONG64 r = InterlockedCompareExchange64(&lb->readPos, 0, 0);

    for (size_t i = 0; i < n; ++i) {
        lb->buffer[w & NTVAD_RING_MASK] = samples[i];
        ++w;
    }

    /* If we ran more than one full ring ahead of the reader, advance the
     * reader so we never overwrite unread data unboundedly. */
    if (w - r > (LONG64)NTVAD_RING_FRAMES) {
        InterlockedExchange64(&lb->readPos, w - (LONG64)NTVAD_RING_FRAMES);
    }
    InterlockedExchange64(&lb->writePos, w);
}

/* Capture side: pull up to n mono float samples, zero-filling on underrun.
 * Returns the number of real (non-silence) samples copied. */
static __inline size_t NTVadLoopbackRead(
    _Inout_ PNTVAD_LOOPBACK lb,
    _Out_writes_(n) float *samples,
    _In_ size_t n)
{
    LONG64 r = InterlockedCompareExchange64(&lb->readPos, 0, 0);
    LONG64 w = InterlockedCompareExchange64(&lb->writePos, 0, 0);
    size_t real = 0;

    while (real < n && r < w) {
        samples[real++] = lb->buffer[r & NTVAD_RING_MASK];
        ++r;
    }
    for (size_t i = real; i < n; ++i) {
        samples[i] = 0.0f;
    }
    InterlockedExchange64(&lb->readPos, r);
    return real;
}
