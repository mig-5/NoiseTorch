/*
 * NoiseTorch Virtual Audio Device (NT-VAD) - loopback ring implementation.
 *
 * Copyright (c) 2026 NoiseTorch-Windows contributors. GPL-3.0.
 */
#include "ntvad_loopback.h"

/* The adapter owns exactly one cable, so a single module-level instance is
 * enough and keeps the SYSVAD delta to a handful of lines. */
static NTVAD_LOOPBACK g_NtvadLoopback;

PNTVAD_LOOPBACK
NtvadLoopbackInstance(VOID)
{
    return &g_NtvadLoopback;
}

#pragma code_seg("INIT")
VOID
NtvadLoopbackInitialize(
    _Out_ PNTVAD_LOOPBACK Loopback)
{
    RtlZeroMemory(Loopback, sizeof(*Loopback));
    KeInitializeSpinLock(&Loopback->Lock);
    Loopback->Initialized = TRUE;
}
#pragma code_seg()

#pragma code_seg()
VOID
NtvadLoopbackWrite(
    _Inout_ PNTVAD_LOOPBACK Loopback,
    _In_reads_bytes_(Length) const UCHAR* Data,
    _In_ ULONG Length)
{
    KIRQL OldIrql;
    ULONG Offset;

    if (Length == 0)
    {
        return;
    }

    KeAcquireSpinLock(&Loopback->Lock, &OldIrql);

    Offset = (ULONG)(Loopback->WritePosition & NTVAD_RING_MASK);
    for (ULONG i = 0; i < Length; ++i)
    {
        Loopback->Buffer[Offset] = Data[i];
        Offset = (Offset + 1u) & NTVAD_RING_MASK;
    }
    Loopback->WritePosition += Length;

    /* Never let the writer lap the reader by more than the whole ring: drop
     * the oldest bytes instead of blocking the render path. */
    if ((Loopback->WritePosition - Loopback->ReadPosition) > (LONG64)NTVAD_RING_BYTES)
    {
        Loopback->ReadPosition = Loopback->WritePosition - (LONG64)NTVAD_RING_BYTES;
    }

    KeReleaseSpinLock(&Loopback->Lock, OldIrql);
}

#pragma code_seg()
VOID
NtvadLoopbackRead(
    _Inout_ PNTVAD_LOOPBACK Loopback,
    _Out_writes_bytes_(Length) UCHAR* Data,
    _In_ ULONG Length)
{
    KIRQL OldIrql;
    ULONG Offset;
    ULONG Copied;

    if (Length == 0)
    {
        return;
    }

    KeAcquireSpinLock(&Loopback->Lock, &OldIrql);

    /* Bound the cable's latency: if the capture endpoint started late (or was
     * paused), skip ahead to the newest few milliseconds instead of replaying
     * everything that piled up at full delay. */
    if ((Loopback->WritePosition - Loopback->ReadPosition) > NTVAD_MAX_BACKLOG)
    {
        Loopback->ReadPosition = Loopback->WritePosition - NTVAD_MAX_BACKLOG;
    }

    Copied = 0;
    Offset = (ULONG)(Loopback->ReadPosition & NTVAD_RING_MASK);
    while (Copied < Length && Loopback->ReadPosition < Loopback->WritePosition)
    {
        Data[Copied++] = Loopback->Buffer[Offset];
        Offset = (Offset + 1u) & NTVAD_RING_MASK;
        ++Loopback->ReadPosition;
    }

    if (Copied < Length)
    {
        RtlZeroMemory(Data + Copied, Length - Copied);
    }

    KeReleaseSpinLock(&Loopback->Lock, OldIrql);
}

#pragma code_seg()
LONG64
NtvadLoopbackAvailable(
    _In_ PNTVAD_LOOPBACK Loopback)
{
    KIRQL OldIrql;
    LONG64 Available;

    KeAcquireSpinLock(&Loopback->Lock, &OldIrql);
    Available = Loopback->WritePosition - Loopback->ReadPosition;
    KeReleaseSpinLock(&Loopback->Lock, OldIrql);

    return Available;
}
