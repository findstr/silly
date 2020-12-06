# silly

[![license](https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat)](https://github.com/findstr/silly/blob/master/LICENSE)
![CI](https://github.com/findstr/silly/workflows/CI/badge.svg?branch=master)

--------

## Depend

- sudo apt-get install libreadline-dev(Debian)
- yum install readline-devel(Centos)

## Build

- make

## Run
    ./silly <config>

## Config

- `daemon`, 1 --> run as daemon, 0 --> normal
- `bootstrap`, lua entry file
- `lualib_path`, will append the package.path (in luaVM)
- `lualib_cpath`, will append the package.cpath (int luaVM)
- `logpath`, when running in daemon mode, all print message will write to `[logpath]/silly-[pid].log` file
- `pidfile`, when running in daemon mode, `pidfile` will used by run only once on a system

## Test

- All test code are in `test` folder
- Run `./silly test/test.conf` to test all module

## Examples

- `examples/start.sh cluster/timer/socket/rpc/http/websocket` can run one example of cluster

## Wiki
https://github.com/findstr/silly/wiki

## Benchmark
https://github.com/findstr/silly/wiki/Benchmark
