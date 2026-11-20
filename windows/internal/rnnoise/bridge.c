/*
 * Single translation unit that pulls in the vendored RNNoise sources so cgo can
 * compile them without copying the upstream submodule. The individual sources
 * are ordinary C files; including them here keeps a single source of truth.
 */
#include "../../../c/rnnoise/src/denoise.c"
#include "../../../c/rnnoise/src/kiss_fft.c"
#include "../../../c/rnnoise/src/pitch.c"
#include "../../../c/rnnoise/src/rnn.c"
#include "../../../c/rnnoise/src/rnn_data.c"
#include "../../../c/rnnoise/src/celt_lpc.c"
