
#!/bin/bash
set -x
mkdir -p /tmp/user-data-test && touch /tmp/user-data-test/user_data_test.sh
echo "User-data executed" > /tmp/user-data-test/debug.log
