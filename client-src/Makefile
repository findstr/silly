all:
	gcc -I ../lua53 -o client main.c -L ../lua53/ -llua -lrt -ldl -lm -Wl,-E
	gcc -I ../lua53 -o socket.so --share -fPIC socket.c
clean:
	-rm main
