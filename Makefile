all:
	make linux -C lua53
	make -C silly-src
	make -C client-src
clean:
	make clean -C lua53
	make clean -C gate-src
	make clean -C silly-src
	rm silly silly.so client
