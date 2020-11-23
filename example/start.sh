#!/bin/sh
echo "start master"
cd ..
./silly example/master/start.conf --master="127.0.0.1:9000" &
sleep 1
./silly example/gate/start.conf --master="127.0.0.1:9000" --gate="127.0.0.1:9001" --gate_listen="127.0.0.1:9002" &
./silly example/gate/start.conf --master="127.0.0.1:9000" --gate="127.0.0.1:9003" --gate_listen="127.0.0.1:9004" &
./silly example/auth/start.conf --master="127.0.0.1:9000" --auth="127.0.0.1:9005" --auth_listen="127.0.0.1:9006" &
./silly example/role/start.conf --master="127.0.0.1:9000" --role="127.0.0.1:9007" &
./silly example/role/start.conf --master="127.0.0.1:9000" --role="127.0.0.1:9008" &
sleep 3 #wait for stable

wait

