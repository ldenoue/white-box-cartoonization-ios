#!/usr/bin/env python3
"""Print the tensor contract and operator inventory for an ONNX model."""

from collections import Counter
from pathlib import Path
import sys

import onnx


def describe(value: onnx.ValueInfoProto) -> str:
    tensor = value.type.tensor_type
    dimensions = []
    for dimension in tensor.shape.dim:
        dimensions.append(str(dimension.dim_value or dimension.dim_param or "?"))
    return f"{value.name}: {onnx.TensorProto.DataType.Name(tensor.elem_type)} [{', '.join(dimensions)}]"


path = Path(sys.argv[1])
model = onnx.load(path)
print(f"IR version: {model.ir_version}")
print(f"Opsets: {[(item.domain or 'ai.onnx', item.version) for item in model.opset_import]}")
print("Inputs:")
for item in model.graph.input:
    print(f"  {describe(item)}")
print("Outputs:")
for item in model.graph.output:
    print(f"  {describe(item)}")
print("Operators:")
for operator, count in sorted(Counter(node.op_type for node in model.graph.node).items()):
    print(f"  {operator}: {count}")
