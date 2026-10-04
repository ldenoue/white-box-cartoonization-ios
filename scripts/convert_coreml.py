#!/usr/bin/env python3
"""Convert the browser's White-box Cartoonization ONNX model to Core ML."""

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn.functional as functional
from onnx2torch import convert


class ImageWrapper(torch.nn.Module):
    """Adapt Core ML's RGB NCHW image convention to the model's BGR NHWC tensors."""

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, rgb_nchw: torch.Tensor) -> torch.Tensor:
        bgr_nhwc = rgb_nchw[:, [2, 1, 0], :, :].permute(0, 2, 3, 1)
        bgr_result = self.model(bgr_nhwc)
        rgb_result = bgr_result[:, :, :, [2, 1, 0]].permute(0, 3, 1, 2)
        return torch.clamp((rgb_result + 1.0) * 127.5, 0.0, 255.0)


class AsymmetricBilinear2x(torch.nn.Module):
    """TensorFlow/ONNX asymmetric bilinear 2× resize, expressed in Core ML-friendly ops."""

    def forward(self, source: torch.Tensor, *_: torch.Tensor) -> torch.Tensor:
        height, width = source.shape[-2:]
        interpolated = functional.interpolate(
            source,
            size=(height * 2 - 1, width * 2 - 1),
            mode="bilinear",
            align_corners=True,
        )
        return functional.pad(interpolated, (0, 1, 0, 1), mode="replicate")


def replace_same_padding(model: onnx.ModelProto) -> None:
    """Make TensorFlow SAME_UPPER padding explicit for the fixed even-sized export."""
    for node in model.graph.node:
        if node.op_type != "Conv":
            continue
        attributes = {attribute.name: attribute for attribute in node.attribute}
        auto_pad = attributes.get("auto_pad")
        if auto_pad is None or onnx.helper.get_attribute_value(auto_pad) != b"SAME_UPPER":
            continue
        kernel = onnx.helper.get_attribute_value(attributes["kernel_shape"])
        strides = onnx.helper.get_attribute_value(attributes["strides"])
        node.attribute.remove(auto_pad)
        if strides == [2, 2] and kernel == [3, 3]:
            pads = [0, 0, 1, 1]
        else:
            half = [(value - 1) // 2 for value in kernel]
            pads = half + half
        node.attribute.append(onnx.helper.make_attribute("pads", pads))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("onnx_model", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--size", type=int, default=256)
    args = parser.parse_args()

    torch.manual_seed(7)
    onnx_model = onnx.load(args.onnx_model)
    replace_same_padding(onnx_model)
    torch_model = convert(onnx_model)
    torch_model._modules["Resize__116"] = AsymmetricBilinear2x()
    torch_model._modules["Resize__157"] = AsymmetricBilinear2x()
    wrapper = ImageWrapper(torch_model).eval()
    sample_pixels = torch.randint(0, 256, (1, 3, args.size, args.size), dtype=torch.float32)
    normalized = sample_pixels / 127.5 - 1.0

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, normalized)
        torch_result = wrapper(normalized).numpy()

    # Catch layout, channel-order, and converter-wrapper mistakes before Core ML conversion.
    onnx_input = normalized[:, [2, 1, 0], :, :].permute(0, 2, 3, 1).numpy()
    session = ort.InferenceSession(str(args.onnx_model), providers=["CPUExecutionProvider"])
    onnx_result = session.run(None, {session.get_inputs()[0].name: onnx_input})[0]
    onnx_rgb = np.clip((onnx_result[:, :, :, ::-1] + 1.0) * 127.5, 0.0, 255.0)
    onnx_rgb = np.transpose(onnx_rgb, (0, 3, 1, 2))
    maximum_difference = float(np.max(np.abs(torch_result - onnx_rgb)))
    print(f"ONNX/PyTorch wrapper max difference: {maximum_difference:.6f}")
    if maximum_difference > 0.05:
        raise RuntimeError("PyTorch conversion differs unexpectedly from ONNX Runtime")

    model = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="source",
                shape=sample_pixels.shape,
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.ImageType(name="cartoon", color_layout=ct.colorlayout.RGB)],
    )
    model.author = "Converted from SystemErrorWang/White-box-Cartoonization model-33999"
    model.short_description = "White-box image cartoonization at 256 × 256"
    model.input_description["source"] = "Square RGB source image"
    model.output_description["cartoon"] = "Square RGB cartoonized image"
    model.user_defined_metadata["source_repository"] = "https://github.com/SystemErrorWang/White-box-Cartoonization"
    model.user_defined_metadata["conversion"] = "ONNX → onnx2torch → Core ML FP16 ML Program"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    model.save(args.output)
    print(f"Saved {args.output}")


if __name__ == "__main__":
    main()
