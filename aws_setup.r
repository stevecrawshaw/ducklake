# Setup for pins and AWS bucket
# aws credentials are in .aws and keeper
#

pacman::p_load(aws.s3, pins, paws.storage, arrow)

bucketlist()

# Create a connection to your S3 bucket
board <- board_s3(
  bucket = "stevecrawshaw-bucket",
  region = "eu-west-2" # Change if your bucket is in a different region
)


# Read the parquet file from S3
df <- read_parquet("s3://stevecrawshaw-bucket/imd2025_england_lsoa21.parquet")

# Write it as a pin
board %>%
  pin_write(
    df,
    name = "imd2025_england_lsoa21",
    type = "parquet",
    title = "IMD 2025 England LSOA21"
  )

# Now it will show up
pin_list(board)

# And you can read it with pins
data <- board %>% pin_read("imd2025_england_lsoa21")
