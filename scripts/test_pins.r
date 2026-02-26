library(pins)
b <- board_s3('stevecrawshaw-bucket', prefix = 'pins/', region = 'eu-west-2')
print(pin_list(b))
