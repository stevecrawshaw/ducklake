"""test_interop.py

Cross-language interop test: read a pin written by R from Python.
Validates that data and custom metadata survive the round-trip.

Usage: uv run python scripts/test_interop.py
"""

import os
import sys

os.environ.setdefault("AWS_DEFAULT_REGION", "eu-west-2")

try:
    from pins import board_s3
except ImportError as e:
    print(f"Import error: {e}")
    print("Install pins with AWS support: pip install 'pins[aws]'")
    sys.exit(1)

# --- Configuration ---
S3_PATH = "stevecrawshaw-bucket/pins"

# --- Create board ---
board = board_s3(S3_PATH, versioned=True)

# --- List pins ---
pin_list = board.pin_list()
print(f"Pins on board: {pin_list}")

if not pin_list:
    print("ERROR: No pins found on S3 board.")
    sys.exit(1)

# --- Read the test pin (first one, or ca_la_lookup_tbl if present) ---
pin_name = "ca_la_lookup_tbl" if "ca_la_lookup_tbl" in pin_list else pin_list[0]
print(f"\nReading pin: {pin_name}")

df = board.pin_read(pin_name)
print(f"DataFrame shape: {df.shape}")
print(f"Dtypes:\n{df.dtypes}")
print(f"\nFirst 3 rows:\n{df.head(3)}")

# --- Read metadata ---
meta = board.pin_meta(pin_name)
print(f"\nPin title: {meta.title}")
print(f"Pin description: {meta.description}")
print(f"Pin type: {meta.type}")

# --- Validate custom metadata ---
user_meta = meta.user
print(f"\nCustom metadata (user): {user_meta}")

if not user_meta:
    print("ERROR: No custom metadata found.")
    sys.exit(1)

columns_meta = user_meta.get("columns")
if not columns_meta:
    print("ERROR: No 'columns' key in custom metadata.")
    sys.exit(1)

if not isinstance(columns_meta, dict) or len(columns_meta) == 0:
    print(f"ERROR: 'columns' metadata is not a non-empty dict: {type(columns_meta)}")
    sys.exit(1)

print(f"\nColumn descriptions ({len(columns_meta)} columns):")
for col_name, col_desc in columns_meta.items():
    print(f"  {col_name}: {col_desc}")

column_types = user_meta.get("column_types")
if column_types:
    print(f"\nColumn types ({len(column_types)} columns):")
    for col_name, col_type in column_types.items():
        print(f"  {col_name}: {col_type}")

print("\nPYTHON INTEROP TEST PASSED")
