// Guard for the safe-math build flags in Tools/build-metallib.sh.
// ProbeTests compares this against the CPU: precise exp stays within a few
// ulp, fast-math exp drifts by tens of ulp at |x| ~ 10. A test that reads the
// compiled behaviour cannot be fooled by a flag that was silently dropped.
#include <metal_stdlib>
using namespace metal;

kernel void probe_exp(device const float *x [[buffer(0)]],
                      device float *y       [[buffer(1)]],
                      uint i                [[thread_position_in_grid]])
{
    y[i] = exp(x[i]);
}
