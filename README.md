# silly([Blog](http://blog.gotocoding.com/?p=446))
--------
##DEPEND

- sudo apt-get install libreadline-dev(debain)
- yum install readline-devel(centos)

##BUILD

- make linux

##RUN

./silly

##CONFIG

- daemon, 1 --> run as daemon, 0 --> normal
- listen_port, the server listen port
- worker_count, open worker count
- bootstrap, the bootstrap for every worker
- lualib_path, will append the package.path (in luaVM)
- lualib_cpath, will append the package.cpath (int luaVM)
