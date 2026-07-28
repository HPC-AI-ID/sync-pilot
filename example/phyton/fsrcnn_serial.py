#!/usr/bin/env python3
"""
fsrcnn_serial.py - Sequential FSRCNN Reference Implementation
Mirrors fsrcnn_syncpilot.py but without threading/pipeline.
"""

import sys
import os
import numpy as np
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fsrcnn_syncpilot import (
    MyVideoFrame,
    weights_layer1, biases_layer1,
    weights_layer2, biases_layer2,
    weights_layer3, biases_layer3,
    weights_layer4, biases_layer4,
    weights_layer5, biases_layer5,
    weights_layer6, biases_layer6,
    weights_layer7, biases_layer7,
    weights_layer8, biases_layer8,
    double_2_uint8,
    pad_image, imfilter, PReLU, deconv,
    layer1, layer2, layer3, layer4, layer5, layer6, layer7, layer8
)


def process_frame(fb):
    for layer_num in range(1, 9):
        rows_in = fb.rows
        cols_in = fb.cols
        scale = fb.scale

        if layer_num == 8:
            out_rows = rows_in * scale
            out_cols = cols_in * scale
            out_ch = 1
        elif layer_num in (1, 7):
            out_rows = rows_in
            out_cols = cols_in
            out_ch = 56
        else:
            out_rows = rows_in
            out_cols = cols_in
            out_ch = 12

        out_data = np.zeros((out_ch, out_rows, out_cols), dtype=np.float64)

        if layer_num == 1:
            layer1(fb.data, out_data, rows_in, cols_in)
        elif layer_num == 2:
            layer2(fb.data, out_data, rows_in, cols_in)
        elif layer_num == 3:
            layer3(fb.data, out_data, rows_in, cols_in)
        elif layer_num == 4:
            layer4(fb.data, out_data, rows_in, cols_in)
        elif layer_num == 5:
            layer5(fb.data, out_data, rows_in, cols_in)
        elif layer_num == 6:
            layer6(fb.data, out_data, rows_in, cols_in)
        elif layer_num == 7:
            layer7(fb.data, out_data, rows_in, cols_in)
        elif layer_num == 8:
            layer8(fb.data, out_data, rows_in, cols_in, scale)

        fb.data = out_data
        fb.rows = out_rows
        fb.cols = out_cols
        fb.channels = out_ch


def main():
    if len(sys.argv) < 3 or len(sys.argv) > 4:
        print("Usage: %s input.yuv output.yuv [num_frames]" % sys.argv[0])
        return 1

    inFile = sys.argv[1]
    outFile = sys.argv[2]
    num_frames = 150
    if len(sys.argv) >= 4:
        num_frames = int(sys.argv[3])

    scale = 2
    inCols = 176
    inRows = 144
    outCols = inCols * scale
    outRows = inRows * scale

    inFp = open(inFile, 'rb')
    g_outFp = open(outFile, 'wb')

    frame_size = inCols * inRows + 2 * (inCols // 2) * (inRows // 2)
    file_size = os.path.getsize(inFile)
    actual_frames = file_size // frame_size
    if actual_frames < num_frames:
        num_frames = actual_frames

    uv_size = (inCols // 2) * (inRows // 2)

    uv_store = []
    yBuf = bytearray(inCols * inRows)
    for f in range(num_frames):
        if inFp.readinto(yBuf) != len(yBuf):
            break
        uv_data = bytearray(2 * uv_size)
        if inFp.readinto(uv_data) != len(uv_data):
            break
        uv_store.append(uv_data)

    inFp.seek(0)
    yBuf = bytearray(inCols * inRows)

    for f in range(num_frames):
        if inFp.readinto(yBuf) != len(yBuf):
            break
        inFp.seek(2 * uv_size, 1)

        lr_data = np.frombuffer(yBuf, dtype=np.uint8).astype(np.float64) / 255.0
        lr_data = lr_data.reshape(inRows, inCols)

        fb = MyVideoFrame(lr_data, inRows, inCols, 1, scale)
        process_frame(fb)

        hr_uint8 = double_2_uint8(fb.data, outCols, outRows)
        g_outFp.write(hr_uint8.tobytes())

        uv_data = uv_store[f]
        u_data = np.frombuffer(uv_data[:uv_size], dtype=np.uint8).reshape(inRows // 2, inCols // 2)
        v_data = np.frombuffer(uv_data[uv_size:], dtype=np.uint8).reshape(inRows // 2, inCols // 2)

        u_rep = np.repeat(np.repeat(u_data, 2, axis=0), 2, axis=1)
        v_rep = np.repeat(np.repeat(v_data, 2, axis=0), 2, axis=1)

        g_outFp.write(u_rep.tobytes())
        g_outFp.write(v_rep.tobytes())

        if (f + 1) % 30 == 0:
            print("Frame %d selesai diproses." % (f + 1))

    inFp.close()
    g_outFp.close()
    print("Selesai. %d frame ditulis." % num_frames)
    return 0


if __name__ == '__main__':
    exit(main())
