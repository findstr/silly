#!/bin/sh
echo "start master"
cd ..
export master="127.0.0.1:9000"
./silly example/master/start.conf &
sleep 1
export gate="127.0.0.1:9001"
export gate_listen="127.0.0.1:9002"
./silly example/gate/start.conf &
export gate="127.0.0.1:9003"
export gate_listen="127.0.0.1:9004"
./silly example/gate/start.conf &
export auth="127.0.0.1:9005"
export auth_listen="127.0.0.1:9006"
./silly example/auth/start.conf &
export role="127.0.0.1:9007"
./silly example/role/start.conf &
export role="127.0.0.1:9008"
./silly example/role/start.conf &
sleep 3 #wait for stable


wait

