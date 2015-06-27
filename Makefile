all:
	make -C gate-src
	make -C server-src
clean:
	make clean -C gate-src
	make clean -C server-src
	rm gate server
