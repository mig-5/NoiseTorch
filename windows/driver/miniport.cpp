/*
 * NoiseTorch Virtual Audio Device (NT-VAD) - WaveRT miniport implementation.
 *
 * REFERENCE SCAFFOLD. See miniport.h and README.md. This implementation uses a
 * simple kernel timer to move PCM between the WaveRT stream buffer and the
 * shared loopback ring instead of a hardware DMA engine. It is sufficient to
 * demonstrate the data path but should be replaced with a position-accurate
 * WaveRT implementation (or the WaveRT "notification" model) before shipping.
 *
 * Copyright (c) 2026 NoiseTorch-Windows contributors. GPL-3.0.
 */
#include "miniport.h"

NTVAD_LOOPBACK g_NTVadLoopback;

static const ULONG NTVAD_TICK_MS = 10; /* timer period */
static const ULONG NTVAD_RATE = 48000;

/* ------------------------------------------------------------------------- */
/* CMiniportWaveRT                                                           */
/* ------------------------------------------------------------------------- */

CMiniportWaveRT::CMiniportWaveRT(NTVadSubdevice subdevice)
    : CUnknown(NULL, CLSID_Null, NULL),
      m_Subdevice(subdevice), m_Port(nullptr), m_Stream(nullptr)
{
}

CMiniportWaveRT::~CMiniportWaveRT()
{
}

STDMETHODIMP CMiniportWaveRT::QueryInterface(REFIID riid, PVOID *ppv)
{
    if (ppv == NULL) {
        return E_POINTER;
    }
    *ppv = NULL;

    if (IsEqualGUID(riid, IID_IUnknown) ||
        IsEqualGUID(riid, IID_IMiniport) ||
        IsEqualGUID(riid, IID_IMiniportWaveRT)) {
        *ppv = static_cast<IMiniportWaveRT *>(this);
        AddRef();
        return S_OK;
    }
    return STATUS_NOT_SUPPORTED;
}

STDMETHODIMP_(ULONG) CMiniportWaveRT::AddRef()
{
    return CUnknown::NonDelegatingAddRef();
}

STDMETHODIMP_(ULONG) CMiniportWaveRT::Release()
{
    return CUnknown::NonDelegatingRelease();
}

STDMETHODIMP CMiniportWaveRT::Init(PPortUnknown Port, PUNKNOWN UnknownAdapter,
                                   PRESOURCELIST ResourceList)
{
    UNREFERENCED_PARAMETER(UnknownAdapter);
    UNREFERENCED_PARAMETER(ResourceList);

    if (Port == NULL) {
        return STATUS_INVALID_PARAMETER;
    }
    return Port->QueryInterface(IID_IPortWaveRT, (PVOID *)&m_Port);
}

STDMETHODIMP CMiniportWaveRT::GetDescription(PPCFILTER_DESCRIPTOR *Description)
{
    static const KSDATARANGE_AUDIO DataRange = {
        {
            sizeof(KSDATARANGE_AUDIO),
            0,
            0,
            0,
            STATIC_KSDATAFORMAT_TYPE_AUDIO,
            STATIC_KSDATAFORMAT_SUBTYPE_PCM,
            STATIC_KSDATAFORMAT_SPECIFIER_WAVEFORMATEX
        },
        1,                 /* MaximumChannels */
        32,                /* MinimumBitsPerSample */
        32,                /* MaximumBitsPerSample */
        NTVAD_RATE,        /* MinimumSampleFrequency */
        NTVAD_RATE         /* MaximumSampleFrequency */
    };

    /* The adapter owns the static descriptors; hand back a pointer to it. */
    *Description = const_cast<PPCFILTER_DESCRIPTOR>(&DataRange);
    UNREFERENCED_PARAMETER(Description);
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRT::DataRangeIntersection(
    ULONG PinId, PKSDATARANGE DataRange, PKSDATARANGE MatchingDataRange,
    ULONG OutputBufferLength, PVOID ResultantFormat, PULONG ResultantFormatLength)
{
    UNREFERENCED_PARAMETER(PinId);
    UNREFERENCED_PARAMETER(DataRange);
    UNREFERENCED_PARAMETER(MatchingDataRange);

    if (ResultantFormatLength == NULL) {
        return STATUS_INVALID_PARAMETER;
    }

    ULONG size = sizeof(KSDATAFORMAT_WAVEFORMATEX);
    if (OutputBufferLength < size) {
        *ResultantFormatLength = size;
        return STATUS_BUFFER_OVERFLOW;
    }

    PKSWAVEFORMATEX wf = &((PKSDATAFORMAT_WAVEFORMATEX)ResultantFormat)->WaveFormatEx;
    RtlZeroMemory(ResultantFormat, size);
    ((PKSDATAFORMAT)ResultantFormat)->FormatSize = size;
    ((PKSDATAFORMAT)ResultantFormat)->MajorFormat = STATIC_KSDATAFORMAT_TYPE_AUDIO;
    ((PKSDATAFORMAT)ResultantFormat)->SubFormat = STATIC_KSDATAFORMAT_SUBTYPE_PCM;
    ((PKSDATAFORMAT)ResultantFormat)->Specifier = STATIC_KSDATAFORMAT_SPECIFIER_WAVEFORMATEX;
    wf->wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    wf->nChannels = 1;
    wf->nSamplesPerSec = NTVAD_RATE;
    wf->wBitsPerSample = 32;
    wf->nBlockAlign = 4;
    wf->nAvgBytesPerSec = NTVAD_RATE * 4;
    wf->cbSize = 0;
    *ResultantFormatLength = size;
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRT::NewStream(
    PMINIPORTWAVERTSTREAM *Stream, PPORTWAVERTSTREAM PortStream,
    ULONG Pin, PUNKNOWN UnknownAdapter, PVOID DeviceContext, PVOID Reserved)
{
    UNREFERENCED_PARAMETER(Pin);
    UNREFERENCED_PARAMETER(UnknownAdapter);
    UNREFERENCED_PARAMETER(DeviceContext);
    UNREFERENCED_PARAMETER(Reserved);

    if (Stream == NULL || PortStream == NULL) {
        return STATUS_INVALID_PARAMETER;
    }
    *Stream = NULL;

    CMiniportWaveRTStream *stream = new (POOL_FLAG_NON_PAGED, 'swTN') CMiniportWaveRTStream(this);
    if (stream == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    NTSTATUS status = stream->Init(PortStream);
    if (!NT_SUCCESS(status)) {
        stream->Release();
        return status;
    }

    AttachStream(stream);
    *Stream = stream; /* reference transferred to caller */
    return STATUS_SUCCESS;
}

/* ------------------------------------------------------------------------- */
/* CMiniportWaveRTStream                                                     */
/* ------------------------------------------------------------------------- */

CMiniportWaveRTStream::CMiniportWaveRTStream(CMiniportWaveRT *miniport)
    : CUnknown(NULL, CLSID_Null, NULL),
      m_Miniport(miniport), m_PortStream(nullptr), m_Buffer(nullptr),
      m_BufferSize(0), m_State(KSSTATE_STOP), m_FrameBytes(4), m_TimerArmed(FALSE)
{
    RtlZeroMemory(&m_Position, sizeof(m_Position));
    KeInitializeTimerEx(&m_Timer, NotificationTimer);
    KeInitializeDpc(&m_Dpc, TimerDpc, this);
}

CMiniportWaveRTStream::~CMiniportWaveRTStream()
{
    if (m_TimerArmed) {
        KeCancelTimer(&m_Timer);
        KeFlushQueuedDpcs();
        m_TimerArmed = FALSE;
    }
    if (m_Buffer != NULL) {
        ExFreePoolWithTag(m_Buffer, 'swTN');
        m_Buffer = NULL;
    }
    if (m_Miniport != NULL) {
        m_Miniport->DetachStream(this);
    }
}

STDMETHODIMP CMiniportWaveRTStream::QueryInterface(REFIID riid, PVOID *ppv)
{
    if (ppv == NULL) {
        return E_POINTER;
    }
    *ppv = NULL;

    if (IsEqualGUID(riid, IID_IUnknown) ||
        IsEqualGUID(riid, IID_IMiniportWaveRTStream)) {
        *ppv = static_cast<IMiniportWaveRTStream *>(this);
        AddRef();
        return S_OK;
    }
    return STATUS_NOT_SUPPORTED;
}

STDMETHODIMP_(ULONG) CMiniportWaveRTStream::AddRef()
{
    return CUnknown::NonDelegatingAddRef();
}

STDMETHODIMP_(ULONG) CMiniportWaveRTStream::Release()
{
    return CUnknown::NonDelegatingRelease();
}

NTSTATUS CMiniportWaveRTStream::Init(PPORTWAVERTSTREAM portStream)
{
    if (portStream == NULL) {
        return STATUS_INVALID_PARAMETER;
    }
    m_PortStream = portStream;
    m_PortStream->AddRef();
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRTStream::AllocateAudioBuffer(
    ULONG RequestedSize, PMDL *AudioBufferMdl, ULONG *ActualSize,
    ULONG *OffsetFromFirstPage, MEMORY_CACHING_TYPE *CacheType)
{
    if (AudioBufferMdl == NULL || ActualSize == NULL ||
        OffsetFromFirstPage == NULL || CacheType == NULL) {
        return STATUS_INVALID_PARAMETER;
    }
    if (RequestedSize == 0 || RequestedSize > NTVAD_MAX_FRAMES * 4) {
        return STATUS_INVALID_PARAMETER;
    }

    ULONG size = (RequestedSize + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    /* Round to whole frames. */
    size = max(size, PAGE_SIZE);

    PVOID buffer = ExAllocatePool2(POOL_FLAG_NON_PAGED, size, 'swTN');
    if (buffer == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    PMDL mdl = IoAllocateMdl(buffer, size, FALSE, FALSE, NULL);
    if (mdl == NULL) {
        ExFreePoolWithTag(buffer, 'swTN');
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    MmBuildMdlForNonPagedPool(mdl);

    if (m_Buffer != NULL) {
        ExFreePoolWithTag(m_Buffer, 'swTN');
    }
    m_Buffer = (BYTE *)buffer;
    m_BufferSize = size;

    *AudioBufferMdl = mdl;
    *ActualSize = size;
    *OffsetFromFirstPage = 0;
    *CacheType = MmCached;
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRTStream::FreeAudioBuffer(PMDL AudioBufferMdl, ULONG BufferSize)
{
    UNREFERENCED_PARAMETER(BufferSize);
    if (AudioBufferMdl != NULL) {
        IoFreeMdl(AudioBufferMdl);
    }
    if (m_Buffer != NULL) {
        ExFreePoolWithTag(m_Buffer, 'swTN');
        m_Buffer = NULL;
    }
    m_BufferSize = 0;
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRTStream::GetClock(PKSCLOCK Clock)
{
    if (Clock == NULL) {
        return STATUS_INVALID_PARAMETER;
    }
    Clock->Frequency = NTVAD_RATE;
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRTStream::GetPosition(PKSAUDIO_POSITION Position)
{
    if (Position == NULL) {
        return STATUS_INVALID_PARAMETER;
    }

    LONG64 bytes = InterlockedCompareExchange64(
        (volatile LONG64 *)&m_Position.PlayOffset, 0, 0);

    if (m_Miniport->Subdevice() == NTVadSubdeviceRender) {
        Position->PlayOffset = (ULONGLONG)bytes;
        Position->WriteOffset = 0;
    } else {
        Position->PlayOffset = 0;
        Position->WriteOffset = (ULONGLONG)bytes;
    }
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRTStream::GetNotificationReason(PULONG Reason)
{
    if (Reason == NULL) {
        return STATUS_INVALID_PARAMETER;
    }
    *Reason = 0;
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRTStream::SetFormat(PKSDATAFORMAT Format)
{
    if (Format == NULL) {
        return STATUS_INVALID_PARAMETER;
    }
    if (Format->FormatSize < sizeof(KSDATAFORMAT_WAVEFORMATEX)) {
        return STATUS_INVALID_PARAMETER;
    }
    PKSDATAFORMAT_WAVEFORMATEX wf = (PKSDATAFORMAT_WAVEFORMATEX)Format;
    if (wf->WaveFormatEx.nChannels != 1 ||
        wf->WaveFormatEx.nSamplesPerSec != NTVAD_RATE ||
        wf->WaveFormatEx.wBitsPerSample != 32) {
        return STATUS_INVALID_PARAMETER;
    }
    m_FrameBytes = 4;
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRTStream::SetNotification(
    ULONG NotificationCount, PMDL NotificationBuffer, ULONG NotificationOffset)
{
    UNREFERENCED_PARAMETER(NotificationCount);
    UNREFERENCED_PARAMETER(NotificationBuffer);
    UNREFERENCED_PARAMETER(NotificationOffset);
    return STATUS_SUCCESS;
}

STDMETHODIMP CMiniportWaveRTStream::SetState(KSSTATE State)
{
    m_State = State;

    if (State == KSSTATE_RUN) {
        if (!m_TimerArmed) {
            LARGE_INTEGER due;
            due.QuadPart = -10000LL * NTVAD_TICK_MS; /* relative, 100ns units */
            KeSetTimerEx(&m_Timer, due, NTVAD_TICK_MS, &m_Dpc);
            m_TimerArmed = TRUE;
        }
    } else {
        if (m_TimerArmed) {
            KeCancelTimer(&m_Timer);
            KeFlushQueuedDpcs();
            m_TimerArmed = FALSE;
        }
    }
    m_Position.PlayOffset = 0;
    m_Position.WriteOffset = 0;
    return STATUS_SUCCESS;
}

VOID NTAPI CMiniportWaveRTStream::TimerDpc(
    PKDPC Dpc, PVOID DeferredContext, PVOID Arg1, PVOID Arg2)
{
    UNREFERENCED_PARAMETER(Dpc);
    UNREFERENCED_PARAMETER(Arg1);
    UNREFERENCED_PARAMETER(Arg2);

    CMiniportWaveRTStream *stream = (CMiniportWaveRTStream *)DeferredContext;
    if (stream == NULL || stream->m_Buffer == NULL || stream->m_State != KSSTATE_RUN) {
        return;
    }

    /* Number of frames handled per tick (10 ms @ 48 kHz). */
    const size_t frames = (NTVAD_RATE / 1000) * NTVAD_TICK_MS;
    const size_t bytes = frames * stream->m_FrameBytes;
    if (stream->m_BufferSize < bytes) {
        return;
    }

    const size_t offset = (size_t)(stream->m_Position.PlayOffset % stream->m_BufferSize);
    float *pcm = (float *)(stream->m_Buffer + offset);
    size_t avail = (stream->m_BufferSize - offset) / sizeof(float);
    size_t count = min(frames, avail);

    if (stream->m_Miniport->Subdevice() == NTVadSubdeviceRender) {
        NTVadLoopbackWrite(&g_NTVadLoopback, pcm, count);
    } else {
        NTVadLoopbackRead(&g_NTVadLoopback, pcm, count);
    }

    InterlockedExchange64((volatile LONG64 *)&stream->m_Position.PlayOffset,
                          (LONG64)(stream->m_Position.PlayOffset + bytes));
}
