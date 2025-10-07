# -*- coding: utf-8 -*-
"""
Decode base64-encoded PNG from PARCS output file
Compatible with Python 2.7 and Python 3.x
Usage: python decode_output.py output.txt map.png
"""
from __future__ import print_function
import sys
import base64

def decode_png(input_file, output_file):
    with open(input_file, 'r') as f:
        content = f.read()
    
    # Extract base64 content between markers
    start_marker = "PNG_BASE64_START\n"
    end_marker = "\nPNG_BASE64_END"
    
    start_idx = content.find(start_marker)
    end_idx = content.find(end_marker)
    
    if start_idx == -1 or end_idx == -1:
        print("ERROR: Could not find base64 markers in output file")
        sys.exit(1)
    
    base64_data = content[start_idx + len(start_marker):end_idx]
    
    # Decode (Python 2/3 compatible)
    try:
        png_data = base64.b64decode(base64_data)
    except Exception as e:
        print("ERROR: Failed to decode base64 data: {}".format(e))
        sys.exit(1)
    
    # Save
    with open(output_file, 'wb') as f:
        f.write(png_data)
    
    size_mb = len(png_data) / (1024.0 * 1024.0)
    print("Successfully decoded {:.2f} MB PNG to {}".format(size_mb, output_file))

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python decode_output.py output.txt map.png")
        sys.exit(1)
    
    decode_png(sys.argv[1], sys.argv[2])
