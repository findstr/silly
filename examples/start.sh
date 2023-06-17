#!/bin/bash

module() {
	./silly --lualib_path="lualib/?.lua;examples/?.lua" --lualib_cpath="luaclib/?.so" --bootstrap="examples/$1.lua"
}

all() {
	array=($(ls examples/*.lua))
	for i in "${array[@]}"; do
		echo "---------------$i-------------------"
		timeout 5 ./silly --lualib_path="lualib/?.lua;examples/?.lua" --lualib_cpath="luaclib/?.so" --bootstrap="$i"
	done
	exit 0
}

case $1 in
	"")
		all;;
	*)
		module $1;;
esac

