"""DuckLake: WECA environment data catalogue and S3 pin pipeline.

Provides Python access to pinned datasets stored on S3.
"""

from pathlib import Path

import pins


def read_pin(
    name: str,
    bucket: str = "stevecrawshaw-bucket",
    prefix: str = "pins/",
    region: str = "eu-west-2",
) -> "pandas.DataFrame":
    """Read a pinned dataset from the WECA S3 board.

    Args:
        name: Pin name (e.g. 'ca_la_lookup_tbl', 'datasets_catalogue').
        bucket: S3 bucket name.
        prefix: S3 key prefix for the pins board.
        region: AWS region.

    Returns:
        DataFrame with the pinned data.
    """
    board = pins.board_s3(bucket=bucket, prefix=prefix, region=region)
    return board.pin_read(name)


def main() -> None:
    """List available pins on the WECA S3 board."""
    board = pins.board_s3(
        bucket="stevecrawshaw-bucket",
        prefix="pins/",
        region="eu-west-2",
    )
    pin_names = board.pin_list()
    print(f"Available pins ({len(pin_names)}):")
    for name in sorted(pin_names):
        print(f"  {name}")


if __name__ == "__main__":
    main()
