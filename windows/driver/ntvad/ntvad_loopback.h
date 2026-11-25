/*
 * NoiseTorch Virtual Audio Device (NT-VAD)
 *
 * Kernel ring buffer that connects the render side of the virtual cable
 * (audio written by the NoiseTorch engine) to its capture side (audio read by
 * conferencing applications).
 *
 * The ring stores raw PCM bytes. Both endpoints of the cable must negotiate the
 * same format (sample rate, channel count and sample size); the NoiseTorch app
 * is responsible for opening the render endpoint with the capture endpoint's
 * mix format.
 *
 * The buffer is statically allocated so it can be touched at DISPATCH_LEVEL
 * without pool allocation, and every operation is serialized by a spin lock.
 *
 * Copyright (c) 2026 NoiseTorch-Windows contributors. GPL-3.0.
 */
#pragma once

#include <ntddk.h>

/* 64 KiB = 341 ms of 48 kHz / 16-bit / stereo PCM. Must be a power of two. */
#define NTVAD_RING_BYTES 65536u
#define NTVAD_RING_MASK  (NTVAD_RING_BYTES - 1u)

/* The capture side never replays more than this much backlog. Without it, a
 * capture stream that starts after the render stream inherits the whole
 * accumulated delay forever, because both sides run at the same rate. 4 KiB
 * is ~21 ms of 48 kHz / 16-bit stereo. */
#define NTVAD_MAX_BACKLOG 4096

typedef struct _NTVAD_LOOPBACK {
    UCHAR        Buffer[NTVAD_RING_BYTES];
    LONG64      WritePosition;   /* advanced by the render path */
    LONG64      ReadPosition;    /* advanced by the capture path */
    KSPIN_LOCK  Lock;
    BOOLEAN     Initialized;
} NTVAD_LOOPBACK, *PNTVAD_LOOPBACK;

/* The single module-level cable instance shared by both endpoints. */
PNTVAD_LOOPBACK NtvadLoopbackInstance(VOID);

/* Called once from DriverEntry. Safe to call again after a reset. */
VOID NtvadLoopbackInitialize(_Out_ PNTVAD_LOOPBACK Loopback);

/* Push bytes produced by the render endpoint. If the capture endpoint falls
 * more than one ring behind, the oldest unread bytes are discarded so the
 * latency stays bounded. */
VOID NtvadLoopbackWrite(
    _Inout_ PNTVAD_LOOPBACK Loopback,
    _In_reads_bytes_(Length) const UCHAR* Data,
    _In_ ULONG Length);

/* Pop bytes for the capture endpoint. Missing bytes are zero-filled, so an
 * idle cable reads as silence instead of repeating stale audio. */
VOID NtvadLoopbackRead(
    _Inout_ PNTVAD_LOOPBACK Loopback,
    _Out_writes_bytes_(Length) UCHAR* Data,
    _In_ ULONG Length);

/* Bytes currently available to the capture endpoint. */
LONG64 NtvadLoopbackAvailable(_In_ PNTVAD_LOOPBACK Loopback);
