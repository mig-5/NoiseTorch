/*
 * NoiseTorch Virtual Audio Device (NT-VAD) - WaveRT miniport.
 *
 * REFERENCE SCAFFOLD: this file documents the intended WaveRT miniport design
 * and the loopback wiring. It must be built against a matching Windows WDK and
 * validated on a test machine (see README.md). It is not compiled as part of
 * the Go build.
 *
 * A single miniport class serves both the render and the capture subdevice.
 * Both streams share one NTVAD_LOOPBACK ring so anything rendered into the
 * virtual cable is immediately available for capture (a virtual microphone).
 *
 * Copyright (c) 2026 NoiseTorch-Windows contributors. GPL-3.0.
 */
#pragma once

#include <portcls.h>
#include <stdunk.h>
#include <ksdebug.h>
#include "loopback.h"

enum NTVadSubdevice {
    NTVadSubdeviceRender = 0,
    NTVadSubdeviceCapture = 1,
    NTVadSubdeviceCount
};

extern NTVAD_LOOPBACK g_NTVadLoopback;

#define NTVAD_MAX_FRAMES 0x30000u /* 4 s of mono float32 @ 48 kHz */

class CMiniportWaveRTStream;

class CMiniportWaveRT : public IMiniportWaveRT,
                        public CUnknown
{
public:
    CMiniportWaveRT(_In_ NTVadSubdevice subdevice);
    ~CMiniportWaveRT();

    /* IUnknown */
    STDMETHODIMP QueryInterface(REFIID, PVOID *);
    STDMETHODIMP_(ULONG) AddRef();
    STDMETHODIMP_(ULONG) Release();

    /* IMiniport */
    STDMETHODIMP Init(PPortUnknown Port, PUNKNOWN UnknownAdapter, PRESOURCELIST ResourceList);
    STDMETHODIMP GetDescription(PPCFILTER_DESCRIPTOR *Description);
    STDMETHODIMP DataRangeIntersection(ULONG PinId, PKSDATARANGE DataRange,
                                       PKSDATARANGE MatchingDataRange,
                                       ULONG OutputBufferLength, PVOID ResultantFormat,
                                       PULONG ResultantFormatLength);
    STDMETHODIMP NewStream(PMINIPORTWAVERTSTREAM *Stream, PPORTWAVERTSTREAM PortStream,
                           ULONG Pin, PUNKNOWN UnknownAdapter, PVOID DeviceContext,
                           PVOID Reserved);

    NTVadSubdevice Subdevice() const { return m_Subdevice; }
    PPORTWAVERT Port() { return m_Port; }

    void AttachStream(CMiniportWaveRTStream *stream) { m_Stream = stream; }
    void DetachStream(CMiniportWaveRTStream *stream)
    {
        if (m_Stream == stream) {
            m_Stream = nullptr;
        }
    }

private:
    NTVadSubdevice          m_Subdevice;
    PPORTWAVERT             m_Port;
    CMiniportWaveRTStream  *m_Stream;
};

class CMiniportWaveRTStream : public IMiniportWaveRTStream,
                              public CUnknown
{
public:
    CMiniportWaveRTStream(_In_ CMiniportWaveRT *miniport);
    ~CMiniportWaveRTStream();

    /* IUnknown */
    STDMETHODIMP QueryInterface(REFIID, PVOID *);
    STDMETHODIMP_(ULONG) AddRef();
    STDMETHODIMP_(ULONG) Release();

    /* IMiniportWaveRTStream */
    STDMETHODIMP AllocateAudioBuffer(ULONG RequestedSize, PMDL *AudioBufferMdl,
                                     ULONG *ActualSize, ULONG *OffsetFromFirstPage,
                                     MEMORY_CACHING_TYPE *CacheType);
    STDMETHODIMP FreeAudioBuffer(PMDL AudioBufferMdl, ULONG BufferSize);
    STDMETHODIMP GetClock(PKSCLOCK Clock);
    STDMETHODIMP GetPosition(PKSAUDIO_POSITION Position);
    STDMETHODIMP GetNotificationReason(PULONG Reason);
    STDMETHODIMP SetFormat(PKSDATAFORMAT Format);
    STDMETHODIMP SetNotification(ULONG NotificationCount, PMDL NotificationBuffer,
                                 ULONG NotificationOffset);
    STDMETHODIMP SetState(KSSTATE State);

private:
    static KDEFERRED_ROUTINE TimerRoutine;
    static VOID NTAPI TimerDpc(PKDPC Dpc, PVOID DeferredContext, PVOID Arg1, PVOID Arg2);

    CMiniportWaveRT       *m_Miniport;
    PPORTWAVERTSTREAM      m_PortStream;
    BYTE                  *m_Buffer;
    ULONG                  m_BufferSize;
    KSSTATE                m_State;
    KSAUDIO_POSITION       m_Position;
    ULONG                  m_FrameBytes;

    KTIMER                 m_Timer;
    KDPC                   m_Dpc;
    BOOLEAN                m_TimerArmed;
};
