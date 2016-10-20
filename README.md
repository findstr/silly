# silly
--------
## Depend

- sudo apt-get install libreadline-dev(debain)
- yum install readline-devel(centos)

## Build

- make linux
- make macosx

## Run
    ./silly <configfile>

## Config

- daemon, 1 --> run as daemon, 0 --> normal
- bootstrap, lua entry file
- lualib_path, will append the package.path (in luaVM)
- lualib_cpath, will append the package.cpath (int luaVM)
- logpath, when run as daemon, all the print will come into [logpath]/silly-[pid].log file

## Test

- all the test code will be included into ./test folder
- run ./silly test/test will auto test all module

## Blog
http://blog.gotocoding.com/?p=446
