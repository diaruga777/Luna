#!/usr/bin/env python3
"""Convert a MobileCLIP2 OpenCLIP model to two Core ML encoders (image + text)
for on-device use in the Pouch Photo Search feature.

Usage (in a venv with: coremltools>=8, torch, open_clip_torch, timm):
    python convert_mobileclip2_coreml.py --variant S0 --out ./out

Produces:
    out/clip_image_<variant>.mlpackage   (image input -> 512-d embedding)
    out/clip_text_<variant>.mlpackage    ([1,77] int32 tokens -> 512-d embedding)

The image model bakes CLIP normalization (mean/std) so the app can feed a raw
RGB image. The text model takes pre-tokenized CLIP BPE token IDs (shape [1,77]).
Both outputs are L2-normalized in-app, so no normalization is baked into outputs.
"""
import argparse
import os
import numpy as np
import torch
import open_clip
import coremltools as ct

CONTEXT_LENGTH = 77

# CLIP normalization constants (OpenCLIP default for MobileCLIP).
MEAN = (0.0, 0.0, 0.0)
STD = (1.0, 1.0, 1.0)


class ImageEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, image):
        return self.model.encode_image(image)


class TextEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, tokens):
        return self.model.encode_text(tokens)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="S0", help="S0, S2, S3, S4, B")
    ap.add_argument("--pretrained", default="dfndr2b")
    ap.add_argument("--out", default="./out")
    ap.add_argument("--size", type=int, default=256)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    model_name = f"MobileCLIP2-{args.variant}"
    print(f"Loading {model_name} ({args.pretrained}) ...")
    model, _, _ = open_clip.create_model_and_transforms(model_name, pretrained=args.pretrained)
    model.eval()
    # Disable the fused multi-head-attention fast path; it emits a
    # `_native_multi_head_attention` op that coremltools can't convert. With the
    # fast path off, attention decomposes into convertible primitive ops.
    try:
        torch.backends.mha.set_fastpath_enabled(False)
    except Exception:
        pass
    # Reparameterize MobileCLIP's train-time blocks for inference if supported.
    if hasattr(model, "image_encoder") and hasattr(model.image_encoder, "reparameterize"):
        model.image_encoder.reparameterize()

    size = args.size
    example_image = torch.rand(1, 3, size, size)
    example_tokens = torch.zeros(1, CONTEXT_LENGTH, dtype=torch.int32)

    with torch.no_grad():
        img_dim = model.encode_image(example_image).shape[-1]
        print("embedding dim:", img_dim)

        traced_image = torch.jit.trace(ImageEncoder(model), example_image)
        traced_text = torch.jit.trace(TextEncoder(model), example_tokens)

    image_input = ct.ImageType(
        name="image", shape=(1, 3, size, size),
        scale=1 / 255.0, bias=[0, 0, 0], color_layout=ct.colorlayout.RGB,
    )
    mlimage = ct.convert(
        traced_image, inputs=[image_input],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
    )
    image_path = os.path.join(args.out, f"clip_image_{args.variant.lower()}.mlpackage")
    mlimage.save(image_path)
    print("saved", image_path)

    text_input = ct.TensorType(name="tokens", shape=(1, CONTEXT_LENGTH), dtype=np.int32)
    mltext = ct.convert(
        traced_text, inputs=[text_input],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
    )
    text_path = os.path.join(args.out, f"clip_text_{args.variant.lower()}.mlpackage")
    mltext.save(text_path)
    print("saved", text_path)


if __name__ == "__main__":
    main()
