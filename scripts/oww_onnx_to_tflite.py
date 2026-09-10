#!/usr/bin/env python3
"""
Convert an openWakeWord ONNX classifier to the .tflite the wyoming service wants.

The off-the-shelf converters were not usable here: onnx2tf treats the [1,16,96]
input as NCW and silently emits [1,96,16], which loads fine and then never
detects anything, and onnx_tf needs onnx<1.14. So instead the graph -- a small
MLP of Gemm/LayerNorm/ReLU blocks ending in a sigmoid -- is rebuilt directly in
Keras with the input shape left alone, and the result is checked against
onnxruntime before it is accepted.
"""
import sys
import numpy as np
import onnx
from onnx import numpy_helper
import tensorflow as tf


def load_weights(path):
    model = onnx.load(path)  # external .onnx.data is picked up automatically
    init = {i.name: numpy_helper.to_array(i) for i in model.graph.initializer}

    gemms, norms, eps = [], [], 1e-5
    pending_scale = None
    for node in model.graph.node:
        attrs = {a.name: a for a in node.attribute}
        if node.op_type == "Gemm":
            w = init[node.input[1]]
            # transB=1 stores the kernel as [out, in]; Keras Dense wants [in, out].
            if attrs.get("transB") is not None and attrs["transB"].i == 1:
                w = w.T
            b = init[node.input[2]] if len(node.input) > 2 else np.zeros(w.shape[1], np.float32)
            gemms.append((np.ascontiguousarray(w, np.float32), b.astype(np.float32)))
        elif node.op_type == "LayerNormalization":
            # Exported straight from PyTorch: scale and bias are explicit inputs.
            norms.append((init[node.input[1]].astype(np.float32),
                          init[node.input[2]].astype(np.float32)))
            if "epsilon" in attrs:
                eps = float(attrs["epsilon"].f)
        # Older exports round-tripped through onnx_tf decompose layer norm into
        # arithmetic, so fall back to reading it back out of those ops.
        elif node.op_type == "Add" and node.input[1] in init and init[node.input[1]].ndim == 0:
            eps = float(init[node.input[1]])
        elif node.op_type == "Mul" and node.input[1] in init and init[node.input[1]].ndim == 1:
            pending_scale = init[node.input[1]].astype(np.float32)
        elif node.op_type == "Add" and node.input[1] in init and init[node.input[1]].ndim == 1:
            if pending_scale is not None:
                norms.append((pending_scale, init[node.input[1]].astype(np.float32)))
                pending_scale = None
    return gemms, norms, eps


def build(gemms, norms, eps, windows=16, features=96):
    # Keras 3 dropped the `weights=` constructor argument, so the graph is built
    # first and the tensors are copied in afterwards by layer name.
    x = inp = tf.keras.Input(batch_size=1, shape=(windows, features), dtype=tf.float32)
    x = tf.keras.layers.Flatten()(x)
    for i, (w, _) in enumerate(gemms[:-1]):
        x = tf.keras.layers.Dense(w.shape[1], name=f"dense{i}")(x)
        x = tf.keras.layers.LayerNormalization(axis=-1, epsilon=eps, name=f"ln{i}")(x)
        x = tf.keras.layers.ReLU()(x)
    out = tf.keras.layers.Dense(gemms[-1][0].shape[1], activation="sigmoid", name="out")(x)
    model = tf.keras.Model(inp, out)

    for i, (w, b) in enumerate(gemms[:-1]):
        model.get_layer(f"dense{i}").set_weights([w, b])
        model.get_layer(f"ln{i}").set_weights(list(norms[i]))
    model.get_layer("out").set_weights(list(gemms[-1]))
    return model


def main(onnx_path, out_path):
    gemms, norms, eps = load_weights(onnx_path)
    print(f"  layers: {[g[0].shape for g in gemms]}  layernorms: {len(norms)}  eps: {eps}")
    windows, features = 16, gemms[0][0].shape[0] // 16

    keras_model = build(gemms, norms, eps, windows, features)
    conv = tf.lite.TFLiteConverter.from_keras_model(keras_model)
    conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
    tflite = conv.convert()
    open(out_path, "wb").write(tflite)

    # Accept the result only if it agrees with the original ONNX.
    import onnxruntime as ort
    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name
    interp = tf.lite.Interpreter(model_content=tflite)
    interp.allocate_tensors()
    di, do = interp.get_input_details()[0], interp.get_output_details()[0]
    print(f"  tflite input shape: {di['shape']}  (want [1 {windows} {features}])")

    worst = 0.0
    rng = np.random.default_rng(0)
    for _ in range(25):
        sample = rng.standard_normal((1, windows, features)).astype(np.float32) * 3
        ref = sess.run(None, {name: sample})[0]
        interp.set_tensor(di["index"], sample)
        interp.invoke()
        worst = max(worst, float(np.abs(ref - interp.get_tensor(do["index"])).max()))
    print(f"  max abs difference vs ONNX over 25 random inputs: {worst:.3e}")
    if worst > 1e-4:
        print("  MISMATCH — refusing to accept this conversion")
        return 1
    print(f"  OK -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
