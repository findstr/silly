#!/bin/bash

module() {
	./silly "examples/$1.lua"
}

all() {
	array=($(ls examples/*.lua))
	for i in "${array[@]}"; do
		echo "---------------$i-------------------"
		timeout 5 ./silly "$i"
	done
	exit 0
}

case $1 in
	"")
		all;;
	*)
		module $1;;
esac

