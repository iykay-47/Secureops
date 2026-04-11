#!/bin/bash

for i in $(seq 1 5); do
  echo "Attempt $i..."
  aws s3 cp test-s3.sh \
    s3://emage-tech-bucket-001/test/attempt-$i.txt \
    --sse AES256 \
    --region us-east-2 \
    --debug 2>&1 | grep -E "HTTP|Error|status"
done
