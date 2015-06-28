all:
	make linux -C lua53
	make -C gate-src
	make -C server-src
	make -C client-src
clean:
	make clean -C lua53
	make clean -C gate-src
	make clean -C server-src
	rm gate server server.so client
