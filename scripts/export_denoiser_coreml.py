#!/usr/bin/env python3
"""Export a denoising to apple CoreML for use in Swift pipelines


Usage:
    pip install coremltools torch numpy einops
    # weights: huggingface.co/deepinv/Restormer (real_denoising.pth)
    #          huggingface.co/nyanko7/nafnet-models (NAFNet-SIDD-width64.pth)
    python scripts/export_denoiser_coreml.py --weights real_denoising.pth --out Restormer.mlpackage
    python scripts/export_denoiser_coreml.py --weights NAFNet-SIDD-width64.pth --out NAFNet.mlpackage

"""
import argparse, importlib.util, os, sys, tempfile, types, urllib.request

RESTORMER_URL = "https://raw.githubusercontent.com/swz30/Restormer/main/basicsr/models/archs/restormer_arch.py"
NAFNET_URL = "https://raw.githubusercontent.com/megvii-research/NAFNet/main/basicsr/models/archs/NAFNet_arch.py"


def fetch_module(url, name):
    """Import a single upstream arch file without cloning the whole repo."""
    src = urllib.request.urlopen(url, timeout=30).read()
    path = os.path.join(tempfile.mkdtemp(), f"{name}.py")
    open(path, "wb").write(src)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build_restormer(state):
    net = fetch_module(RESTORMER_URL, "restormer_arch").Restormer(
        inp_channels=3, out_channels=3, dim=48, num_blocks=[4, 6, 6, 8], num_refinement_blocks=4,
        heads=[1, 2, 4, 8], ffn_expansion_factor=2.66, bias=False,
        # WithBias keeps a `.body.bias`; BiasFree does not — read it off the weights.
        LayerNorm_type="WithBias" if any(k.endswith(".body.bias") for k in state) else "BiasFree",
        dual_pixel_task=False)
    net.load_state_dict(state, strict=True)
    return net.eval()


def build_nafnet(state):
    import torch, torch.nn as nn
    # NAFNet_arch imports LayerNorm2d / Local_Base from basicsr; supply inference-
    # equivalent stubs (matching param names) so we avoid the whole basicsr dep.
    class LayerNorm2d(nn.Module):
        def __init__(self, channels, eps=1e-6):
            super().__init__()
            self.weight = nn.Parameter(torch.ones(channels))
            self.bias = nn.Parameter(torch.zeros(channels))
            self.eps = eps

        def forward(self, x):
            mu = x.mean(1, keepdim=True)
            var = (x - mu).pow(2).mean(1, keepdim=True)
            return self.weight.view(1, -1, 1, 1) * ((x - mu) / (var + self.eps).sqrt()) + self.bias.view(1, -1, 1, 1)

    arch_util = types.ModuleType("basicsr.models.archs.arch_util"); arch_util.LayerNorm2d = LayerNorm2d
    local_arch = types.ModuleType("basicsr.models.archs.local_arch"); local_arch.Local_Base = type("Local_Base", (), {})
    for name, mod in [("basicsr", None), ("basicsr.models", None), ("basicsr.models.archs", None),
                      ("basicsr.models.archs.arch_util", arch_util), ("basicsr.models.archs.local_arch", local_arch)]:
        sys.modules.setdefault(name, mod or types.ModuleType(name))

    net = fetch_module(NAFNET_URL, "nafnet_arch").NAFNet(
        img_channel=3, width=64, enc_blk_nums=[2, 2, 4, 8], middle_blk_num=12, dec_blk_nums=[2, 2, 2, 2])
    net.load_state_dict(state, strict=True)
    return net.eval()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True, help="Restormer or NAFNet .pth state dict")
    ap.add_argument("--size", type=int, default=512, help="fixed square tile (÷16)")
    ap.add_argument("--out", default="Denoiser.mlpackage")
    args = ap.parse_args()
    assert args.size % 16 == 0, "size must be divisible by 16 (both U-Nets downsample ×16)"

    import torch, numpy as np, coremltools as ct

    ckpt = torch.load(args.weights, map_location="cpu")
    state = ckpt.get("params", ckpt) if isinstance(ckpt, dict) else ckpt
    is_nafnet = any(k.startswith("intro.") for k in state)
    net = build_nafnet(state) if is_nafnet else build_restormer(state)

    example = torch.rand(1, 3, args.size, args.size)
    with torch.no_grad():
        traced = torch.jit.trace(net, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS18,   # macOS 15 / iOS 18
        compute_units=ct.ComputeUnit.CPU_AND_GPU,    # these nets don't lower to the ANE
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = f"{'NAFNet' if is_nafnet else 'Restormer'} denoiser (NTIRE backbone)"
    mlmodel.save(args.out)
    print(f"wrote {args.out}  ({'NAFNet' if is_nafnet else 'Restormer'}, {args.size}x{args.size}, fp16)", file=sys.stderr)


if __name__ == "__main__":
    main()
