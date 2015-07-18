# silly
--------
##depend library:

- sudo apt-get install libreadline-dev(debain)
- yum install readline-devel(centos)

##build

- make linux

##run

./silly

##config

- deamon, 1 --> run as deamon, 0 --> normal
- listen_port, the server listen port
- worker_count, open worker count
- bootstrap, the bootstrap for every worker
- lualib_path, will append the package.path (in luaVM)
- lualib_cpath, will append the package.cpath (int luaVM)
