// The upstream extension declares four CUDA launchers and branches on
// input.device().is_cuda(). On a Mac nothing is ever a CUDA tensor, so these
// are unreachable; they exist only so the CPU path links without nvcc.
#include <torch/extension.h>
#define SPK_NO_CUDA TORCH_CHECK(false, "ailut: built without CUDA")
void LutTransformForwardCUDAKernelLauncher(const torch::Tensor&, const torch::Tensor&, torch::Tensor) { SPK_NO_CUDA; }
void LutTransformBackwardCUDAKernelLauncher(const torch::Tensor&, const torch::Tensor&, const torch::Tensor&, torch::Tensor, torch::Tensor) { SPK_NO_CUDA; }
void AiLutTransformForwardCUDAKernelLauncher(const torch::Tensor&, const torch::Tensor&, const torch::Tensor&, torch::Tensor) { SPK_NO_CUDA; }
void AiLutTransformBackwardCUDAKernelLauncher(const torch::Tensor&, const torch::Tensor&, const torch::Tensor&, const torch::Tensor&, torch::Tensor, torch::Tensor, torch::Tensor) { SPK_NO_CUDA; }
