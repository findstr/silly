#!/bin/sh

cluster() {
	echo "start master"
	./silly examples/cluster/master/start.conf --master="127.0.0.1:9000" &
	sleep 1
	./silly examples/cluster/gate/start.conf --master="127.0.0.1:9000" --gate="127.0.0.1:9001" --gate_listen="127.0.0.1:9002" &
	./silly examples/cluster/gate/start.conf --master="127.0.0.1:9000" --gate="127.0.0.1:9003" --gate_listen="127.0.0.1:9004" &
	./silly examples/cluster/auth/start.conf --master="127.0.0.1:9000" --auth="127.0.0.1:9005" --auth_listen="127.0.0.1:9006" &
	./silly examples/cluster/role/start.conf --master="127.0.0.1:9000" --role="127.0.0.1:9007" &
	./silly examples/cluster/role/start.conf --master="127.0.0.1:9000" --role="127.0.0.1:9008" &
	sleep 3 #wait for stable
	wait
}

module() {
	./silly --lualib_path="lualib/?.lua;examples/?.lua" --lualib_cpath="luaclib/?.so" --bootstrap="examples/$1.lua"
}

all() {
	array=($(ls examples/*.lua))
	for i in "${array[@]}"; do
		echo "---------------$i-------------------"
		timeout 5 ./silly --lualib_path="lualib/?.lua" --lualib_cpath="luaclib/?.so" --bootstrap="$i"
	done
	cluster
	sleep 30
	exit 0
}

case $1 in
	"cluster")
		cluster;;
	"")
		all;;
	*)
		module $1;;
esac

